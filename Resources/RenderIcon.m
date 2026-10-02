#import <AppKit/AppKit.h>
#import "../Sources/Symbols.h"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) return 1;
        NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:1024 pixelsHigh:1024 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        [NSGraphicsContext saveGraphicsState];
        NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
        [[NSColor colorWithSRGBRed:0.965 green:0.965 blue:0.955 alpha:1] setFill];
        NSBezierPath *tile = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(64, 64, 896, 896) xRadius:196 yRadius:196];
        [tile fill];
        [[NSColor colorWithWhite:0 alpha:0.10] setStroke];
        tile.lineWidth = 2;
        [tile stroke];
        // The transparent note is cut out of a separate symbol layer, not the tile.
        NSImage *symbol = [NSImage imageWithSize:NSMakeSize(540, 600) flipped:NO drawingHandler:^BOOL(NSRect rect) {
            UVDrawUSBNote(rect, [NSColor colorWithSRGBRed:0.15 green:0.17 blue:0.18 alpha:1]);
            return YES;
        }];
        [symbol drawInRect:NSMakeRect(242, 212, 540, 600)];
        [NSGraphicsContext restoreGraphicsState];
        NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        return [png writeToFile:[NSString stringWithUTF8String:argv[1]] atomically:YES] ? 0 : 2;
    }
}
