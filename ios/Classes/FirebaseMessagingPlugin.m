// Copyright 2017 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "FirebaseMessagingPlugin.h"

#import "Firebase/Firebase.h"

#import <UserNotifications/UserNotifications.h>

#if defined(__IPHONE_10_0) && __IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_10_0
@interface FLTFirebaseMessagingPlugin () <FIRMessagingDelegate, UNUserNotificationCenterDelegate>
@end
#endif

@implementation FLTFirebaseMessagingPlugin {
    FlutterMethodChannel *_channel;
    NSDictionary *_launchNotification;
    BOOL _resumingFromBackground;
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    FlutterMethodChannel *channel =
    [FlutterMethodChannel methodChannelWithName:@"plugins.flutter.io/firebase_messaging"
                                binaryMessenger:[registrar messenger]];
    FLTFirebaseMessagingPlugin *instance =
    [[FLTFirebaseMessagingPlugin alloc] initWithChannel:channel];
    [registrar addApplicationDelegate:instance];
    [registrar addMethodCallDelegate:instance channel:channel];
}

- (instancetype)initWithChannel:(FlutterMethodChannel *)channel {
    self = [super init];

    if (self) {
        _channel = channel;
        _resumingFromBackground = NO;
        if (![FIRApp appNamed:@"__FIRAPP_DEFAULT"]) {
            NSLog(@"Configuring the default Firebase app...");
            [FIRApp configure];
            NSLog(@"Configured the default Firebase app %@.", [FIRApp defaultApp].name);
        }
        [FIRMessaging messaging].delegate = self;
    }
    return self;
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
    NSString *method = call.method;
    if ([@"requestNotificationPermissions" isEqualToString:method]) {
        if (@available(iOS 10.0, *)) {
            // iOS 10 or later
            // For iOS 10 display notification (sent via APNS)
            [UNUserNotificationCenter currentNotificationCenter].delegate = self;
            UNAuthorizationOptions authOptions = UNAuthorizationOptionAlert |
            UNAuthorizationOptionSound | UNAuthorizationOptionBadge;
            [[UNUserNotificationCenter currentNotificationCenter]
             requestAuthorizationWithOptions:authOptions
             completionHandler:^(BOOL granted, NSError * _Nullable error) {
                 // ...
             }];
            
        } else {
            // Fallback on earlier versions
            UIUserNotificationType notificationTypes = 0;
            NSDictionary *arguments = call.arguments;
            if ([arguments[@"sound"] boolValue]) {
                notificationTypes |= UIUserNotificationTypeSound;
            }
            if ([arguments[@"alert"] boolValue]) {
                notificationTypes |= UIUserNotificationTypeAlert;
            }
            if ([arguments[@"badge"] boolValue]) {
                notificationTypes |= UIUserNotificationTypeBadge;
            }
            UIUserNotificationSettings *settings =
            [UIUserNotificationSettings settingsForTypes:notificationTypes categories:nil];
            [[UIApplication sharedApplication] registerUserNotificationSettings:settings];
            
        }
        
        result(nil);
    } else if ([@"configure" isEqualToString:method]) {
        [FIRMessaging messaging].shouldEstablishDirectChannel = true;
        [[UIApplication sharedApplication] registerForRemoteNotifications];
        if (_launchNotification != nil) {
            [_channel invokeMethod:@"onLaunch" arguments:_launchNotification];
        }
        result(nil);
    } else if ([@"subscribeToTopic" isEqualToString:method]) {
        NSString *topic = call.arguments;
        [[FIRMessaging messaging] subscribeToTopic:topic completion:^(NSError * _Nullable error) {
            if (error == nil) {
                result(nil);
            } else {
                if (error.userInfo) {
                    NSLog(@"subscribeToTopic error %@", error.userInfo);
                }
                result([NSString stringWithFormat:@"subscribeToTopic failed"]);
            }
        }];
    } else if ([@"unsubscribeFromTopic" isEqualToString:method]) {
        NSString *topic = call.arguments;
        [[FIRMessaging messaging] unsubscribeFromTopic:topic completion:^(NSError * _Nullable error) {
            if (error == nil) {
                result(nil);
            } else {
                if (error.userInfo) {
                    NSLog(@"unsubscribeFromTopic error %@", error.userInfo);
                }
                result([NSString stringWithFormat:@"unsubscribeFromTopic failed"]);
            }
        }];
    } else if ([@"getToken" isEqualToString:method]) {
        [[FIRInstanceID instanceID]
         instanceIDWithHandler:^(FIRInstanceIDResult *_Nullable instanceIDResult,
                                 NSError *_Nullable error) {
             if (error != nil) {
                 NSLog(@"getToken, error fetching instanceID: %@", error);
                 result(nil);
             } else {
                 result(instanceIDResult.token);
             }
         }];
    } else if ([@"deleteInstanceID" isEqualToString:method]) {
        [[FIRInstanceID instanceID] deleteIDWithHandler:^void(NSError *_Nullable error) {
            if (error.code != 0) {
                NSLog(@"deleteInstanceID, error: %@", error);
                result([NSNumber numberWithBool:NO]);
            } else {
                [[UIApplication sharedApplication] unregisterForRemoteNotifications];
                result([NSNumber numberWithBool:YES]);
            }
        }];
    } else if ([@"autoInitEnabled" isEqualToString:method]) {
        BOOL value = [[FIRMessaging messaging] isAutoInitEnabled];
        result([NSNumber numberWithBool:value]);
    } else if ([@"setAutoInitEnabled" isEqualToString:method]) {
        NSNumber *value = call.arguments;
        [FIRMessaging messaging].autoInitEnabled = value.boolValue;
        result(nil);
    } else {
        result(FlutterMethodNotImplemented);
    }
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center didReceiveNotificationResponse:(UNNotificationResponse *)response withCompletionHandler:(void(^)(void))completionHandler API_AVAILABLE(ios(10.0)) {
    NSDictionary *userInfo = response.notification.request.content.userInfo;

    NSDictionary *newUserInfo = [self rebuildUserInfo:response.notification];
    if(newUserInfo != nil) {
        userInfo = newUserInfo;
    }

    // With swizzling disabled you must let Messaging know about the message, for Analytics
    [[FIRMessaging messaging] appDidReceiveMessage:userInfo];
    [self didReceiveRemoteNotification:userInfo];
}

// [START ios_10_message_handling]
// Receive displayed notifications for iOS 10 devices.
// Handle incoming notification messages while app is in the foreground.
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler  API_AVAILABLE(ios(10.0)){
    NSDictionary *userInfo = notification.request.content.userInfo;

    NSDictionary *newUserInfo = [self rebuildUserInfo:notification];
    if(newUserInfo != nil) {
        userInfo = newUserInfo;
    }

    // With swizzling disabled you must let Messaging know about the message, for Analytics
    [[FIRMessaging messaging] appDidReceiveMessage:userInfo];
    [self didReceiveRemoteNotification:userInfo];
}

- (NSDictionary*)rebuildGimbalNotification:(NSDictionary*)userInfo {
    NSArray* userInfoKeys = [userInfo allKeys];
    if([userInfoKeys containsObject:@"ATTRS"] && [userInfoKeys containsObject:@"TL"]) {
        NSString* title = [userInfo objectForKey:@"TL"];
        if(title == nil || [title isKindOfClass:[NSNull class]]) {
            title = [NSString stringWithFormat:@""];;
        }
        if([userInfoKeys containsObject:@"aps"] && [[userInfo objectForKey:@"aps"] isKindOfClass:[NSDictionary class]]) {
            NSDictionary* apsValue = [userInfo objectForKey:@"aps"];
            if([[apsValue allKeys]containsObject:@"alert"]) {
                NSString* bodyValue = [apsValue objectForKey:@"alert"];
                if(bodyValue == nil || [bodyValue isKindOfClass:[NSNull class]]) {
                    bodyValue = [NSString stringWithFormat:@""];
                }
                NSDictionary* alertDictionary = [NSDictionary dictionaryWithObjectsAndKeys:[NSDictionary dictionaryWithObjectsAndKeys:title, @"title", bodyValue, @"body", nil], @"alert", nil];
                NSMutableDictionary* userInfoMutableDictionary = [NSMutableDictionary dictionaryWithDictionary:userInfo];
                [userInfoMutableDictionary setValue:alertDictionary forKey:@"aps"];
                [userInfoMutableDictionary setValue:@"GimbalType" forKey:@"kNotificationChannelType"];
                return userInfoMutableDictionary;
            }
        }
    }
    return nil;
}

- (NSDictionary*)rebuildUserInfo:(UNNotification *)notification API_AVAILABLE(ios(10.0)) {
    NSDictionary *userInfo = notification.request.content.userInfo;
    //Receive Gimbal notification
    NSArray* userInfoKeys = [userInfo allKeys];
    if([userInfoKeys containsObject:@"ATTRS"] && [userInfoKeys containsObject:@"TL"]) {
        return [self rebuildGimbalNotification:userInfo];
    } else if ([userInfoKeys containsObject:@"GMBL_COMMUNICATION"]) {
        //Receive Gimbal place notification
        NSString* bodyValue = notification.request.content.body.description;
        if(bodyValue == nil || [bodyValue isKindOfClass:[NSNull class]]) {
            bodyValue = [NSString stringWithFormat:@""];
        }
        NSMutableDictionary* userInfoMutableDictionary = [NSMutableDictionary dictionaryWithDictionary:userInfo];
        NSDictionary* alertDictionary = [NSDictionary dictionaryWithObjectsAndKeys:[NSDictionary dictionaryWithObjectsAndKeys:@"", @"title", bodyValue, @"body", nil], @"alert", nil];
        [userInfoMutableDictionary setValue:alertDictionary forKey:@"aps"];
        [userInfoMutableDictionary setValue:@"GimbalType" forKey:@"kNotificationChannelType"];
        return userInfoMutableDictionary;
    }
    return nil;
}

#if defined(__IPHONE_10_0) && __IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_10_0
// Receive data message on iOS 10 devices while app is in the foreground.
- (void)applicationReceivedRemoteMessage:(FIRMessagingRemoteMessage *)remoteMessage {
    [self didReceiveRemoteNotification:remoteMessage.appData];
}
#endif

- (void)didReceiveRemoteNotification:(NSDictionary *)userInfo {
    if (_resumingFromBackground) {
        [_channel invokeMethod:@"onResume" arguments:userInfo];
    } else {
        [_channel invokeMethod:@"onMessage" arguments:userInfo];
    }
}

#pragma mark - AppDelegate

- (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {

    if (@available(iOS 10.0, *)) {
        UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
        center.delegate = self;
    }

    if (launchOptions != nil) {
        _launchNotification = launchOptions[UIApplicationLaunchOptionsRemoteNotificationKey];
        NSDictionary* newLaunchNotification = [self rebuildGimbalNotification:_launchNotification];
        if (newLaunchNotification != nil) {
            _launchNotification = newLaunchNotification;
        }
    }
    return YES;
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    _resumingFromBackground = YES;
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    _resumingFromBackground = NO;
    // Clears push notifications from the notification center, with the
    // side effect of resetting the badge count. We need to clear notifications
    // because otherwise the user could tap notifications in the notification
    // center while the app is in the foreground, and we wouldn't be able to
    // distinguish that case from the case where a message came in and the
    // user dismissed the notification center without tapping anything.
    // TODO(goderbauer): Revisit this behavior once we provide an API for managing
    // the badge number, or if we add support for running Dart in the background.
    // Setting badgeNumber to 0 is a no-op (= notifications will not be cleared)
    // if it is already 0,
    // therefore the next line is setting it to 1 first before clearing it again
    // to remove all
    // notifications.
//    application.applicationIconBadgeNumber = 1;
//    application.applicationIconBadgeNumber = 0;
}

- (bool)application:(UIApplication *)application
didReceiveRemoteNotification:(NSDictionary *)userInfo
fetchCompletionHandler:(void (^)(UIBackgroundFetchResult result))completionHandler {
    [[FIRMessaging messaging] appDidReceiveMessage:userInfo];
    [self didReceiveRemoteNotification:userInfo];
    completionHandler(UIBackgroundFetchResultNoData);
    return YES;
}

- (void)application:(UIApplication *)application
didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken {
#ifdef DEBUG
    [[FIRMessaging messaging] setAPNSToken:deviceToken type:FIRMessagingAPNSTokenTypeSandbox];
#else
    [[FIRMessaging messaging] setAPNSToken:deviceToken type:FIRMessagingAPNSTokenTypeProd];
#endif

    [_channel invokeMethod:@"onToken" arguments:[FIRMessaging messaging].FCMToken];
}

- (void)application:(UIApplication *)application
didRegisterUserNotificationSettings:(UIUserNotificationSettings *)notificationSettings {
    NSDictionary *settingsDictionary = @{
                                         @"sound" : [NSNumber numberWithBool:notificationSettings.types & UIUserNotificationTypeSound],
                                         @"badge" : [NSNumber numberWithBool:notificationSettings.types & UIUserNotificationTypeBadge],
                                         @"alert" : [NSNumber numberWithBool:notificationSettings.types & UIUserNotificationTypeAlert],
                                         };
    [_channel invokeMethod:@"onIosSettingsRegistered" arguments:settingsDictionary];
}

- (void)messaging:(nonnull FIRMessaging *)messaging
didReceiveRegistrationToken:(nonnull NSString *)fcmToken {
    [_channel invokeMethod:@"onToken" arguments:fcmToken];
}

- (void)messaging:(FIRMessaging *)messaging
didReceiveMessage:(FIRMessagingRemoteMessage *)remoteMessage {
    [_channel invokeMethod:@"onMessage" arguments:remoteMessage.appData];
}

@end
