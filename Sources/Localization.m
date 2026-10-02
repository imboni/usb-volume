#import "Localization.h"

NSString *const UVLanguageDidChangeNotification = @"UVLanguageDidChange";
static NSString *const UVLanguagePreference = @"USBVolume.language";
static NSString *UVResolvedLanguage;

NSArray<NSDictionary<NSString *, NSString *> *> *UVAvailableLanguages(void) {
    static NSArray *languages;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        languages = @[
            @{@"code":@"en", @"nativeName":@"English"},
            @{@"code":@"zh-Hans", @"nativeName":@"简体中文"},
            @{@"code":@"zh-Hant", @"nativeName":@"繁體中文"},
            @{@"code":@"ja", @"nativeName":@"日本語"},
            @{@"code":@"ko", @"nativeName":@"한국어"},
            @{@"code":@"fr", @"nativeName":@"Français"},
            @{@"code":@"de", @"nativeName":@"Deutsch"},
            @{@"code":@"es", @"nativeName":@"Español"},
            @{@"code":@"it", @"nativeName":@"Italiano"},
            @{@"code":@"pt-BR", @"nativeName":@"Português (Brasil)"},
            @{@"code":@"ru", @"nativeName":@"Русский"},
            @{@"code":@"ar", @"nativeName":@"العربية"},
            @{@"code":@"hi", @"nativeName":@"हिन्दी"},
            @{@"code":@"id", @"nativeName":@"Bahasa Indonesia"}
        ];
    });
    return languages;
}

static NSArray<NSString *> *UVLanguageCodes(void) {
    return [UVAvailableLanguages() valueForKey:@"code"];
}

NSString *UVLanguageOverride(void) {
    NSString *value = [NSUserDefaults.standardUserDefaults stringForKey:UVLanguagePreference];
    return value && [UVLanguageCodes() containsObject:value] ? value : @"";
}

NSString *UVResolveLanguage(NSString *override, NSArray<NSString *> *preferredLanguages) {
    NSArray *codes = UVLanguageCodes();
    if ([codes containsObject:override]) return override;
    NSString *match = [NSBundle preferredLocalizationsFromArray:codes forPreferences:preferredLanguages].firstObject;
    return match && [codes containsObject:match] ? match : @"en";
}

NSString *UVCurrentLanguage(void) {
    if (!UVResolvedLanguage) UVResolvedLanguage = UVResolveLanguage(UVLanguageOverride(), NSLocale.preferredLanguages);
    return UVResolvedLanguage;
}

NSString *UVStringForLanguage(NSString *key, NSString *language) {
    // Main-bundle lookup remains explicit so a language change applies without
    // touching AppleLanguages, restarting the app, or interrupting its audio.
    NSString *(^lookup)(NSString *) = ^NSString *(NSString *code) {
        NSString *path = [NSBundle.mainBundle pathForResource:code ofType:@"lproj"];
        NSBundle *bundle = path ? [NSBundle bundleWithPath:path] : nil;
        return bundle ? [bundle localizedStringForKey:key value:@"__UV_MISSING__" table:@"Localizable"] : @"__UV_MISSING__";
    };
    NSString *value = lookup(language);
    if ([value isEqualToString:@"__UV_MISSING__"]) value = lookup(@"en");
    return [value isEqualToString:@"__UV_MISSING__"] ? key : value;
}

NSString *UVL(NSString *key) { return UVStringForLanguage(key, UVCurrentLanguage()); }
BOOL UVIsRightToLeft(void) { return [UVCurrentLanguage() isEqualToString:@"ar"]; }

void UVRefreshLanguage(void) {
    NSString *old = UVCurrentLanguage();
    NSString *current = UVResolveLanguage(UVLanguageOverride(), NSLocale.preferredLanguages);
    if ([old isEqualToString:current]) return;
    UVResolvedLanguage = current;
    [NSNotificationCenter.defaultCenter postNotificationName:UVLanguageDidChangeNotification object:nil];
}

void UVSetLanguageOverride(NSString *language) {
    NSCAssert(NSThread.isMainThread, @"Language changes must be made on the main thread.");
    (void)UVCurrentLanguage();
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([UVLanguageCodes() containsObject:language]) [defaults setObject:language forKey:UVLanguagePreference];
    else [defaults removeObjectForKey:UVLanguagePreference];
    UVRefreshLanguage();
}
