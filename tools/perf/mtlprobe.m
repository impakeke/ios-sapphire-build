// mtlprobe: ¿recibe un proceso cualquiera un dispositivo Metal? Imprime el nombre del dispositivo o "nil".
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
int main(void) { @autoreleasepool {
    id<MTLDevice> d = MTLCreateSystemDefaultDevice();
    printf("MTLCreateSystemDefaultDevice: %s\n", d ? [[d name] UTF8String] : "nil");
    if (d) { id<MTLCommandQueue> q = [d newCommandQueue]; printf("newCommandQueue: %s\n", q ? "ok" : "nil"); }
} return 0; }
