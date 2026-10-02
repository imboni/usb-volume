#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
extern NSString *const UVLanguageDidChangeNotification;
NSString *UVL(NSString *key);
NSArray<NSDictionary<NSString *, NSString *> *> *UVAvailableLanguages(void);
NSString *UVLanguageOverride(void);
NSString *UVCurrentLanguage(void);
NSString *UVResolveLanguage(NSString *override, NSArray<NSString *> *preferredLanguages);
NSString *UVStringForLanguage(NSString *key, NSString *language);
BOOL UVIsRightToLeft(void);
void UVSetLanguageOverride(NSString *language);
void UVRefreshLanguage(void);
NS_ASSUME_NONNULL_END
