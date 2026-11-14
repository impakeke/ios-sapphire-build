// Puente USB(IOUSBHost) <-> TCP para adb, porque libusb/IOUSBLib están rotos en esta Hackintosh.
// Uso: adbbridge [puerto]   luego: adb connect 127.0.0.1:puerto
#import <Foundation/Foundation.h>
#import <IOUSBHost/IOUSBHost.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <unistd.h>

static IOUSBHostPipe *inPipe, *outPipe;
static NSUInteger outMPS = 512;

static int readFull(int fd, uint8_t *b, size_t n) {
  size_t g = 0; while (g < n) { ssize_t r = read(fd, b + g, n - g); if (r <= 0) return -1; g += r; } return 0;
}
static int writeFull(int fd, const uint8_t *b, size_t n) {
  size_t g = 0; while (g < n) { ssize_t r = write(fd, b + g, n - g); if (r <= 0) return -1; g += r; } return 0;
}
static int usbOut(const uint8_t *b, size_t n) {
  NSMutableData *d = [NSMutableData dataWithBytes:b length:n];
  NSUInteger done = 0; NSError *e = nil;
  if (![outPipe sendIORequestWithData:d bytesTransferred:&done completionTimeout:0 error:&e] || done != n) {
    NSLog(@"usb out error: %@", e); return -1; }
  if (n > 0 && n % outMPS == 0) { // ZLP
    NSMutableData *z = [NSMutableData dataWithLength:0];
    [outPipe sendIORequestWithData:z bytesTransferred:&done completionTimeout:0 error:&e];
  }
  return 0;
}
// lee exactamente n bytes del endpoint IN (puede llegar en varias transferencias)
static int usbIn(uint8_t *b, size_t n) {
  size_t g = 0;
  while (g < n) {
    size_t want = n - g;
    NSMutableData *d = [NSMutableData dataWithLength:want];
    NSUInteger done = 0; NSError *e = nil;
    if (![inPipe sendIORequestWithData:d bytesTransferred:&done completionTimeout:0 error:&e]) {
      NSLog(@"usb in error: %@", e); return -1; }
    memcpy(b + g, d.bytes, done); g += done;
  }
  return 0;
}

int main(int argc, char **argv) { @autoreleasepool {
  int port = argc > 1 ? atoi(argv[1]) : 6555;
  // buscar interfaz ADB: clase 255, subclase 66, protocolo 1
  // el matching por propiedades no funciona aquí: recorrer las interfaces y filtrar a mano
  io_iterator_t it = 0; io_service_t svc = 0, s;
  IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostInterface"), &it);
  while ((s = IOIteratorNext(it))) {
    int v[3] = {0}; const char *k[3] = {"bInterfaceClass", "bInterfaceSubClass", "bInterfaceProtocol"};
    for (int j = 0; j < 3; j++) {
      CFTypeRef p = IORegistryEntryCreateCFProperty(s, (__bridge CFStringRef)@(k[j]), NULL, 0);
      if (p) { v[j] = [(__bridge NSNumber *)p intValue]; CFRelease(p); }
    }
    if (v[0] == 255 && v[1] == 66 && v[2] == 1) { svc = s; break; }
    IOObjectRelease(s);
  }
  if (!svc) { fprintf(stderr, "no hay interfaz ADB\n"); return 1; }
  NSError *err = nil;
  IOUSBHostInterface *iface = [[IOUSBHostInterface alloc] initWithIOService:svc options:IOUSBHostObjectInitOptionsNone queue:nil error:&err interestHandler:nil];
  if (!iface) { NSLog(@"open: %@", err); return 1; }
  const IOUSBConfigurationDescriptor *cd = iface.configurationDescriptor;
  const IOUSBInterfaceDescriptor *id_ = iface.interfaceDescriptor;
  const IOUSBEndpointDescriptor *ep = NULL;
  while ((ep = IOUSBGetNextEndpointDescriptor(cd, id_, (const IOUSBDescriptorHeader *)ep))) {
    if ((ep->bmAttributes & 3) != 2) continue;
    IOUSBHostPipe *p = [iface copyPipeWithAddress:ep->bEndpointAddress error:&err];
    if (ep->bEndpointAddress & 0x80) inPipe = p; else { outPipe = p; outMPS = USBToHost16(ep->wMaxPacketSize) & 0x7ff; }
    printf("endpoint 0x%02x mps %d\n", ep->bEndpointAddress, USBToHost16(ep->wMaxPacketSize) & 0x7ff);
  }
  if (!inPipe || !outPipe) { fprintf(stderr, "faltan endpoints\n"); return 1; }

  int ls = socket(AF_INET, SOCK_STREAM, 0); int one = 1;
  setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons(port), .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
  if (bind(ls, (void *)&a, sizeof a) || listen(ls, 1)) { perror("bind"); return 1; }
  printf("escuchando en 127.0.0.1:%d\n", port); fflush(stdout);

  for (;;) {
    int c = accept(ls, NULL, NULL); if (c < 0) continue;
    { NSError *e2 = nil;
      [inPipe abortWithOption:IOUSBHostAbortOptionSynchronous error:nil]; [outPipe abortWithOption:IOUSBHostAbortOptionSynchronous error:nil];
      if (![inPipe clearStallWithError:&e2]) NSLog(@"clearStall in: %@", e2);
      if (![outPipe clearStallWithError:&e2]) NSLog(@"clearStall out: %@", e2); }
    setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    printf("cliente conectado\n"); fflush(stdout);
    __block volatile int alive = 1;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    // TCP -> USB
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
      uint8_t h[24]; uint8_t *buf = malloc(1 << 20 | 64);
      while (alive) {
        if (readFull(c, h, 24)) break;
        uint32_t len; memcpy(&len, h + 12, 4);
        if (len > (1 << 20)) { NSLog(@"len raro %u", len); break; }
        if (len && readFull(c, buf, len)) break;
        if (usbOut(h, 24)) break;
        if (len && usbOut(buf, len)) break;
      }
      alive = 0; free(buf); shutdown(c, SHUT_RDWR); dispatch_semaphore_signal(done);
    });
    // USB -> TCP
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
      uint8_t h[24]; uint8_t *buf = malloc(1 << 20 | 64);
      while (alive) {
        if (usbIn(h, 24)) break;
        uint32_t len; memcpy(&len, h + 12, 4);
        if (len > (1 << 20)) { NSLog(@"len raro dev %u", len); break; }
        if (len && usbIn(buf, len)) break;
        if (writeFull(c, h, 24)) break;
        if (len && writeFull(c, buf, len)) break;
      }
      alive = 0; free(buf); shutdown(c, SHUT_RDWR); dispatch_semaphore_signal(done);
    });
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    // el hilo USB->TCP puede quedar bloqueado en un read; abortar para liberarlo
    [inPipe abortWithOption:IOUSBHostAbortOptionSynchronous error:nil];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    close(c); printf("cliente desconectado\n"); fflush(stdout);
  }
}}
