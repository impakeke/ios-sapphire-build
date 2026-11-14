// Cliente fastboot mínimo por IOUSBHost (libusb/IOUSBLib rotos en esta Hackintosh).
// Uso: fbusb getvar:all | getvar:current-slot | download+flash <part> <archivo> | set_active:b | reboot | <cmd crudo>
// Compilar: clang -fobjc-arc -framework Foundation -framework IOKit -framework IOUSBHost fbusb.m -o fbusb
#import <Foundation/Foundation.h>
#import <IOUSBHost/IOUSBHost.h>

static IOUSBHostPipe *inP, *outP;

static int usbOut(const void *b, size_t n) {
  NSMutableData *d = [NSMutableData dataWithBytes:b length:n];
  NSUInteger done = 0; NSError *e = nil;
  if (![outP sendIORequestWithData:d bytesTransferred:&done completionTimeout:30 error:&e] || done != n) {
    fprintf(stderr, "usb out error: %s\n", e.description.UTF8String); return -1; }
  return 0;
}
// lee una respuesta; imprime INFO/TEXT, devuelve 0=OKAY 1=FAIL 2=DATA (y *dlen) -1=error
static int resp(uint32_t *dlen, char *out, size_t outn) {
  for (;;) {
    NSMutableData *d = [NSMutableData dataWithLength:512];
    NSUInteger got = 0; NSError *e = nil;
    if (![inP sendIORequestWithData:d bytesTransferred:&got completionTimeout:120 error:&e]) {
      fprintf(stderr, "usb in error: %s\n", e.description.UTF8String); return -1; }
    char s[520] = {0}; memcpy(s, d.bytes, got);
    if (!strncmp(s, "INFO", 4) || !strncmp(s, "TEXT", 4)) { printf("(bootloader) %s\n", s + 4); continue; }
    if (!strncmp(s, "OKAY", 4)) { if (out) snprintf(out, outn, "%s", s + 4); if (s[4]) printf("%s\n", s + 4); return 0; }
    if (!strncmp(s, "FAIL", 4)) { printf("FAIL: %s\n", s + 4); return 1; }
    if (!strncmp(s, "DATA", 4)) { if (dlen) *dlen = (uint32_t)strtoul(s + 4, NULL, 16); return 2; }
    printf("respuesta rara: %s\n", s);
  }
}
static int cmd(const char *c, char *out, size_t outn) {
  printf("> %s\n", c);
  if (usbOut(c, strlen(c))) return -1;
  return resp(NULL, out, outn);
}
static int downloadFile(const char *path) {
  NSData *f = [NSData dataWithContentsOfFile:@(path)];
  if (!f) { fprintf(stderr, "no puedo leer %s\n", path); return -1; }
  char c[64]; snprintf(c, sizeof c, "download:%08lx", (unsigned long)f.length);
  printf("> %s (%lu bytes)\n", c, (unsigned long)f.length);
  if (usbOut(c, strlen(c))) return -1;
  uint32_t dl = 0; int r = resp(&dl, NULL, 0);
  if (r != 2) return -1;
  const uint8_t *p = f.bytes; size_t left = f.length, off = 0, chunk = 1 << 20;
  while (left) {
    size_t n = left < chunk ? left : chunk;
    if (usbOut(p + off, n)) return -1;
    off += n; left -= n;
    if ((off >> 20) % 8 == 0 || !left) { printf("\r  enviado %zu/%lu MB", off >> 20, (unsigned long)f.length >> 20); fflush(stdout); }
  }
  printf("\n");
  return resp(NULL, NULL, 0);
}

int main(int argc, char **argv) { @autoreleasepool {
  // el matching por propiedades no funciona aquí: recorrer todas las interfaces y filtrar a mano
  io_iterator_t it = 0; io_service_t svc = 0, s;
  IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostInterface"), &it);
  while ((s = IOIteratorNext(it))) {
    int v[3] = {0}; const char *k[3] = {"bInterfaceClass", "bInterfaceSubClass", "bInterfaceProtocol"};
    for (int j = 0; j < 3; j++) {
      CFTypeRef p = IORegistryEntryCreateCFProperty(s, (__bridge CFStringRef)@(k[j]), NULL, 0);
      if (p) { v[j] = [(__bridge NSNumber *)p intValue]; CFRelease(p); }
    }
    if (v[0] == 255 && v[1] == 66 && v[2] == 3) { svc = s; break; }
    IOObjectRelease(s);
  }
  if (!svc) { fprintf(stderr, "no hay interfaz fastboot\n"); return 1; }
  NSError *err = nil;
  IOUSBHostInterface *iface = [[IOUSBHostInterface alloc] initWithIOService:svc options:IOUSBHostObjectInitOptionsNone queue:nil error:&err interestHandler:nil];
  if (!iface) { fprintf(stderr, "open: %s\n", err.description.UTF8String); return 1; }
  const IOUSBEndpointDescriptor *ep = NULL;
  while ((ep = IOUSBGetNextEndpointDescriptor(iface.configurationDescriptor, iface.interfaceDescriptor, (const IOUSBDescriptorHeader *)ep))) {
    if ((ep->bmAttributes & 3) != 2) continue;
    IOUSBHostPipe *p = [iface copyPipeWithAddress:ep->bEndpointAddress error:&err];
    if (ep->bEndpointAddress & 0x80) inP = p; else outP = p;
  }
  if (!inP || !outP) { fprintf(stderr, "faltan endpoints\n"); return 1; }
  int rc = 0;
  for (int i = 1; i < argc && rc == 0; i++) {
    if (!strcmp(argv[i], "flash") && i + 2 < argc) {
      rc = downloadFile(argv[i + 2]);
      if (rc == 0) { char c[128]; snprintf(c, sizeof c, "flash:%s", argv[i + 1]); rc = cmd(c, NULL, 0); }
      i += 2;
    } else rc = cmd(argv[i], NULL, 0);
  }
  return rc ? 1 : 0;
}}
