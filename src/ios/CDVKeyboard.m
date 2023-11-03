/*
 Licensed to the Apache Software Foundation (ASF) under one
 or more contributor license agreements.  See the NOTICE file
 distributed with this work for additional information
 regarding copyright ownership.  The ASF licenses this file
 to you under the Apache License, Version 2.0 (the
 "License"); you may not use this file except in compliance
 with the License.  You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing,
 software distributed under the License is distributed on an
 "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 KIND, either express or implied.  See the License for the
 specific language governing permissions and limitations
 under the License.
 */

#import "CDVKeyboard.h"
#import <Cordova/CDVAvailability.h>
#import <objc/runtime.h>
#import <Cordova/CDVViewController.h>
#import "CDVStatusBar.h"



#ifndef __CORDOVA_3_2_0
#warning "The keyboard plugin is only supported in Cordova 3.2 or greater, it may not work properly in an older version. If you do use this plugin in an older version, make sure the HideKeyboardFormAccessoryBar and KeyboardShrinksView preference values are false."
#endif

@interface CDVKeyboard () <UIScrollViewDelegate>

@property (nonatomic, readwrite, assign) BOOL keyboardIsVisible;

// Add a property to store the previous keyboard frame
@property (nonatomic, readwrite, assign) CGRect previousKeyboardFrame;

// Gets the device iOS version
@property (nonatomic, readwrite, assign) NSString *deviceVersion;

// checks if the focused element is bottomsheet input fields or not
@property (nonatomic, readwrite, assign) BOOL isInputInBottomSheet;

@end

@implementation CDVKeyboard

- (id)settingForKey:(NSString*)key
{
    return [self.commandDelegate.settings objectForKey:[key lowercaseString]];
}

#pragma mark Initialize

- (void)pluginInitialize
{
    NSString* setting = nil;

    self.deviceVersion = [[UIDevice currentDevice] systemVersion];
    NSLog(@"Device Version: %@", self.deviceVersion);

    setting = @"HideKeyboardFormAccessoryBar";
    if ([self settingForKey:setting]) {
      self.hideFormAccessoryBar = [(NSNumber*)[self settingForKey:setting] boolValue];
    }

    setting = @"KeyboardShrinksView";
    if ([self settingForKey:setting]) {
      self.shrinkView = [(NSNumber*)[self settingForKey:setting] boolValue];
    }

    setting = @"DisableScrollingWhenKeyboardShrinksView";
    if ([self settingForKey:setting]) {
      self.disableScrollingInShrinkView = [(NSNumber*)[self settingForKey:setting] boolValue];
    }

    NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
    __weak CDVKeyboard* weakSelf = self;

    // observer to check the app state, this gets triggered when app is moved to background or inactive
    [nc addObserver:self selector:@selector(appWillResignActive:) name:UIApplicationWillResignActiveNotification object:nil];

    _keyboardHideObserver = [nc addObserverForName:UIKeyboardDidHideNotification object:nil
        queue:[NSOperationQueue mainQueue]
        usingBlock:^(NSNotification* notification) {
            [weakSelf.commandDelegate evalJs:@"Keyboard.fireOnHide();"];
            weakSelf.previousKeyboardFrame = CGRectZero;
        }];

    _keyboardWillShowObserver = [nc addObserverForName:UIKeyboardWillShowNotification
      object:nil
      queue:[NSOperationQueue mainQueue]
      usingBlock:^(NSNotification* notification) {
        [weakSelf.commandDelegate evalJs:@"Keyboard.fireOnShowing();"];
        weakSelf.keyboardIsVisible = YES;
      }];
    _keyboardWillHideObserver = [nc addObserverForName:UIKeyboardWillHideNotification
      object:nil
      queue:[NSOperationQueue mainQueue]
      usingBlock:^(NSNotification* notification) {
        [weakSelf.commandDelegate evalJs:@"Keyboard.fireOnHiding();"];
        weakSelf.keyboardIsVisible = NO;
      }];

    _shrinkViewKeyboardWillChangeFrameObserver = [nc addObserverForName:UIKeyboardWillChangeFrameNotification
     object:nil
     queue:[NSOperationQueue mainQueue]
     usingBlock:^(NSNotification* notification) {
        if (self.shrinkView) {
            [weakSelf performSelector:@selector(shrinkViewKeyboardWillChangeFrame:) withObject:notification afterDelay:0];

            // custom javascript to check if the focused input field is bottomsheet, if yes then it does not calculates screen height
            if ([self.webView isKindOfClass:NSClassFromString(@"UIWebView")]) {
                NSString *js = @"function isFocusedInputInBottomSheet() { var focused = document.activeElement; var body = document.body; while (focused) { if (focused.parentElement === body && focused.tagName === 'DIV') { return true; } focused = focused.parentElement; } return false; } isFocusedInputInBottomSheet();";
                NSString *result = [(UIWebView *)self.webView stringByEvaluatingJavaScriptFromString:js];
                self.isInputInBottomSheet = [result boolValue];
            }
        }
    }];

    self.webView.scrollView.delegate = self;
}

#pragma mark HideFormAccessoryBar

static IMP UIOriginalImp;
static IMP WKOriginalImp;

- (void)setHideFormAccessoryBar:(BOOL)hideFormAccessoryBar
{
    if (hideFormAccessoryBar == _hideFormAccessoryBar) {
        return;
    }

    NSString* UIClassString = [@[@"UI", @"Web", @"Browser", @"View"] componentsJoinedByString:@""];
    NSString* WKClassString = [@[@"WK", @"Content", @"View"] componentsJoinedByString:@""];

    Method UIMethod = class_getInstanceMethod(NSClassFromString(UIClassString), @selector(inputAccessoryView));
    Method WKMethod = class_getInstanceMethod(NSClassFromString(WKClassString), @selector(inputAccessoryView));

    if (hideFormAccessoryBar) {
        UIOriginalImp = method_getImplementation(UIMethod);
        WKOriginalImp = method_getImplementation(WKMethod);

        IMP newImp = imp_implementationWithBlock(^(id _s) {
            return nil;
        });

        method_setImplementation(UIMethod, newImp);
        method_setImplementation(WKMethod, newImp);
    } else {
        method_setImplementation(UIMethod, UIOriginalImp);
        method_setImplementation(WKMethod, WKOriginalImp);
    }

    _hideFormAccessoryBar = hideFormAccessoryBar;
}

#pragma mark KeyboardShrinksView

- (void)setShrinkView:(BOOL)shrinkView
{
    // Remove WKWebView's keyboard observers when using shrinkView
    // They've caused several issues with the plugin (#32, #55, #64)
    // Even if you later set shrinkView to false, the observers will not be added back
    NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
    if ([self.webView isKindOfClass:NSClassFromString(@"WKWebView")]) {
        [nc removeObserver:self.webView name:UIKeyboardWillHideNotification object:nil];
        [nc removeObserver:self.webView name:UIKeyboardWillShowNotification object:nil];
        [nc removeObserver:self.webView name:UIKeyboardWillChangeFrameNotification object:nil];
        [nc removeObserver:self.webView name:UIKeyboardDidChangeFrameNotification object:nil];
    }
    _shrinkView = shrinkView;
}

- (void)appWillResignActive:(NSNotification *)notification {
    // Dismiss the keyboard
    [self.webView endEditing:YES];
}

- (void)shrinkViewKeyboardWillChangeFrame:(NSNotification*)notif
{
    // No-op on iOS 7.0.  It already resizes webview by default, and this plugin is causing layout issues
    // with fixed position elements.  We possibly should attempt to implement shrinkview = false on iOS7.0.
    // iOS 7.1+ behave the same way as iOS 6
    if (NSFoundationVersionNumber < NSFoundationVersionNumber_iOS_7_1 && NSFoundationVersionNumber > NSFoundationVersionNumber_iOS_6_1) {
        return;
    }

    // If the view is not visible, we should do nothing. E.g. if the inappbrowser is open.
    if (!(self.viewController.isViewLoaded && self.viewController.view.window)) {
        return;
    }

    self.webView.scrollView.scrollEnabled = YES;

    CGRect screen = [[UIScreen mainScreen] bounds];
    CGRect statusBar = [[UIApplication sharedApplication] statusBarFrame];
    CGRect keyboard = ((NSValue*)notif.userInfo[@"UIKeyboardFrameEndUserInfoKey"]).CGRectValue;

    // Work within the webview's coordinate system
    keyboard = [self.webView convertRect:keyboard fromView:nil];
    statusBar = [self.webView convertRect:statusBar fromView:nil];
    screen = [self.webView convertRect:screen fromView:nil];

    CDVViewController* vc = (CDVViewController*)self.viewController;
    CDVStatusBar *statusBarPlugin = [vc getCommandInstance:@"StatusBar"];
    BOOL statusBarOverlaysWebView = statusBarPlugin.statusBarOverlaysWebView;

    // if the webview is below the status bar, offset and shrink its frame
    if (!statusBarOverlaysWebView) {
        CGRect full, remainder;
        CGRectDivide(screen, &remainder, &full, statusBar.size.height, CGRectMinYEdge);
        screen = full;
    }

    // Define a threshold for what constitutes a "significant" change in keyboard height
    CGFloat threshold = 20.0; // Adjust this value as needed
    bool keyboardSwitch = false;

    // Check if the keyboard frame has changed significantly (indicating a keyboard type change)
    if (!CGRectIsNull(self.previousKeyboardFrame) && !CGRectEqualToRect(self.previousKeyboardFrame, CGRectZero) && fabs(CGRectGetHeight(self.previousKeyboardFrame) - CGRectGetHeight(keyboard)) > threshold) {
        keyboardSwitch = true;
    }

    if(!CGRectEqualToRect(self.previousKeyboardFrame, keyboard)) {
        self.previousKeyboardFrame = keyboard;
    }

    CGFloat animationDuration = [notif.userInfo[UIKeyboardAnimationDurationUserInfoKey] floatValue];
    // Get the intersection of the keyboard and screen and move the webview above it
    // Note: we check for _shrinkView at this point instead of the beginning of the method to handle
    // the case where the user disabled shrinkView while the keyboard is showing.
    // The webview should always be able to return to full size
    CGRect keyboardIntersection = CGRectIntersection(screen, keyboard);
    if (CGRectContainsRect(screen, keyboardIntersection) && !CGRectIsEmpty(keyboardIntersection) && _shrinkView && self.keyboardIsVisible && !keyboardSwitch) {
        if(!self.isInputInBottomSheet) {
            self.webView.scrollView.scrollEnabled = !self.disableScrollingInShrinkView; // Order intentionally swapped.
            screen.size.height -= keyboardIntersection.size.height;

            // Change the content size as it creates a blank space in iOS 15 devices (works for all versions)
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(animationDuration * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                CGSize revisedSize = CGSizeMake(self.webView.scrollView.frame.size.width, self.webView.scrollView.frame.size.height - keyboard.size.height);
                    self.webView.scrollView.contentSize = revisedSize;
            });
            }

            // Fixes the iOS 15.5 black blank space above the keyboard and resets the webview correctly.
            if(![self.deviceVersion isEqual:@"15.5"] && ![self.deviceVersion isEqual:@"15.4"]) {
                // Custom implementation to have the header and footer sticky
                UIEdgeInsets contentInsets = UIEdgeInsetsMake(0.0, 0.0, keyboardIntersection.size.height, 0.0);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(animationDuration * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                    self.webView.scrollView.contentInset = contentInsets;
                    self.webView.scrollView.scrollIndicatorInsets = contentInsets;
                });
            }
        } else {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.0 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                UIEdgeInsets contentInsets = UIEdgeInsetsZero;
                self.webView.scrollView.contentInset = contentInsets;
                self.webView.scrollView.scrollIndicatorInsets = contentInsets;
            });
        }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(animationDuration * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            // A view's frame is in its superview's coordinate system so we need to convert again
            self.webView.frame = [self.webView.superview convertRect:screen fromView:self.webView];

        if(!self.isInputInBottomSheet) {
            CGSize revisedSize = CGSizeMake(self.webView.frame.size.width, self.webView.frame.size.height - keyboard.size.height);
            self.webView.scrollView.contentSize = revisedSize;
        }
    });
}

#pragma mark UIScrollViewDelegate

- (void)scrollViewDidScroll:(UIScrollView*)scrollView
{
    if (_shrinkView && _keyboardIsVisible) {
        CGFloat maxY = scrollView.contentSize.height - scrollView.bounds.size.height;
        if (scrollView.bounds.origin.y > maxY) {
            scrollView.bounds = CGRectMake(scrollView.bounds.origin.x, 0, scrollView.bounds.size.width, scrollView.bounds.size.height);
        }
    }
}

#pragma mark Plugin interface

- (void)shrinkView:(CDVInvokedUrlCommand*)command
{
    if (command.arguments.count > 0) {
        id value = [command.arguments objectAtIndex:0];
        if (!([value isKindOfClass:[NSNumber class]])) {
            value = [NSNumber numberWithBool:NO];
        }

        self.shrinkView = [value boolValue];
    }

    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsBool:self.shrinkView]
                                callbackId:command.callbackId];
}

- (void)disableScrollingInShrinkView:(CDVInvokedUrlCommand*)command
{
    if (command.arguments.count > 0) {
        id value = [command.arguments objectAtIndex:0];
        if (!([value isKindOfClass:[NSNumber class]])) {
            value = [NSNumber numberWithBool:NO];
        }

        self.disableScrollingInShrinkView = [value boolValue];
    }

    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsBool:self.disableScrollingInShrinkView]
                                callbackId:command.callbackId];
}

- (void)hideFormAccessoryBar:(CDVInvokedUrlCommand*)command
{
    if (command.arguments.count > 0) {
        id value = [command.arguments objectAtIndex:0];
        if (!([value isKindOfClass:[NSNumber class]])) {
            value = [NSNumber numberWithBool:NO];
        }

        self.hideFormAccessoryBar = [value boolValue];
    }

    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsBool:self.hideFormAccessoryBar]
                                callbackId:command.callbackId];
}

- (void)hide:(CDVInvokedUrlCommand*)command
{
    [self.webView endEditing:YES];
}

#pragma mark dealloc

- (void)dealloc
{
    // since this is ARC, remove observers only
    NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];

    [nc removeObserver:self name:UIApplicationWillResignActiveNotification object:nil];
    [nc removeObserver:_keyboardShowObserver];
    [nc removeObserver:_keyboardHideObserver];
    [nc removeObserver:_keyboardWillShowObserver];
    [nc removeObserver:_keyboardWillHideObserver];
    [nc removeObserver:_shrinkViewKeyboardWillChangeFrameObserver];
}

@end
