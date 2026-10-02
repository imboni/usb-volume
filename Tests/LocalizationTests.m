#import "../Sources/Localization.h"
#include <assert.h>

int main(void) {
    @autoreleasepool {
        assert([UVResolveLanguage(@"de", @[@"zh-Hans-CN"]) isEqualToString:@"de"]);
        assert([UVResolveLanguage(@"", @[@"zh-TW"]) isEqualToString:@"zh-Hant"]);
        assert([UVResolveLanguage(@"", @[@"zh-CN"]) isEqualToString:@"zh-Hans"]);
        assert([UVResolveLanguage(@"", @[@"pt-PT"]) isEqualToString:@"pt-BR"]);
        assert([UVResolveLanguage(@"", @[@"en-GB"]) isEqualToString:@"en"]);
        assert([UVResolveLanguage(@"invalid", @[@"ja-JP"]) isEqualToString:@"ja"]);
        assert([UVResolveLanguage(@"", @[@"xx-YY"]) isEqualToString:@"en"]);
        assert([UVStringForLanguage(@"设置", @"de") isEqualToString:@"Einstellungen"]);
        assert([UVStringForLanguage(@"设置", @"unknown") isEqualToString:@"Settings"]);
        assert([UVStringForLanguage(@"missing-key", @"de") isEqualToString:@"missing-key"]);
        // Keep preference changes in this test process's volatile argument domain.
        [NSUserDefaults.standardUserDefaults setVolatileDomain:@{@"USBVolume.language":@"ar"} forName:NSArgumentDomain];
        UVRefreshLanguage();
        assert(UVIsRightToLeft());
        [NSUserDefaults.standardUserDefaults setVolatileDomain:@{@"USBVolume.language":@"en"} forName:NSArgumentDomain];
        __block NSUInteger notifications = 0;
        id observer = [NSNotificationCenter.defaultCenter addObserverForName:UVLanguageDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *note) { (void)note; notifications++; }];
        UVRefreshLanguage();
        assert(!UVIsRightToLeft() && notifications == 1);
        assert([UVL(@"设置") isEqualToString:@"Settings"]);
        [NSNotificationCenter.defaultCenter removeObserver:observer];
        puts("Localization: region matching, fallback, runtime refresh and RTL passed.");
    }
    return 0;
}
