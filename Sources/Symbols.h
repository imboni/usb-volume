#import <AppKit/AppKit.h>

// One silhouette, shared by the app icon and the menu bar: a USB plug with a note.
static inline void UVDrawUSBNote(NSRect rect, NSColor *ink) {
    [NSGraphicsContext saveGraphicsState];
    NSAffineTransform *transform = [NSAffineTransform transform];
    [transform translateXBy:rect.origin.x yBy:rect.origin.y];
    [transform scaleXBy:rect.size.width / 18.0 yBy:rect.size.height / 20.0];
    [transform concat];
    [ink setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(5, 11, 8, 8) xRadius:0.9 yRadius:0.9] fill];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(3, 1, 12, 12) xRadius:2.6 yRadius:2.6] fill];
    NSRectFillUsingOperation(NSMakeRect(6.5, 14.6, 1.5, 2.5), NSCompositingOperationClear);
    NSRectFillUsingOperation(NSMakeRect(10, 14.6, 1.5, 2.5), NSCompositingOperationClear);
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    CGContextSetBlendMode(context, kCGBlendModeClear);
    NSBezierPath *note = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(6, 3.5, 3.8, 2.7)];
    [note fill];
    NSBezierPath *stem = [NSBezierPath bezierPath];
    [stem moveToPoint:NSMakePoint(9.25, 5.0)];
    [stem lineToPoint:NSMakePoint(9.25, 10.5)];
    stem.lineWidth = 1.15;
    stem.lineCapStyle = NSLineCapStyleRound;
    [stem stroke];
    NSBezierPath *flag = [NSBezierPath bezierPath];
    [flag moveToPoint:NSMakePoint(9.15, 10.6)];
    [flag curveToPoint:NSMakePoint(11.85, 8.25) controlPoint1:NSMakePoint(10.1, 10.1) controlPoint2:NSMakePoint(12.2, 9.6)];
    [flag curveToPoint:NSMakePoint(9.15, 9.05) controlPoint1:NSMakePoint(11.3, 9.05) controlPoint2:NSMakePoint(10.35, 8.7)];
    [flag closePath];
    [flag fill];
    [NSGraphicsContext restoreGraphicsState];
}

static inline NSImage *UVStatusImage(BOOL muted) {
    NSImage *image = [NSImage imageWithSize:NSMakeSize(18, 20) flipped:NO drawingHandler:^BOOL(NSRect bounds) {
        UVDrawUSBNote(bounds, [NSColor colorWithWhite:0 alpha:muted ? 0.45 : 1]);
        return YES;
    }];
    image.template = YES;
    return image;
}
