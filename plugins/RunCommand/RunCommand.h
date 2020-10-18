//
//  RunCommand.h
//  kdeconnect-ios
//
//  Created by Inoki on 18/10/2020.
//  Copyright © 2020 Inoki. All rights reserved.
//

#ifndef RunCommand_h
#define RunCommand_h

#import "Plugin.h"

@interface RunCommand : Plugin

@property(nonatomic) Device* _device;
@property(nonatomic) id _pluginDelegate;
@property(nonatomic) NSString *_lockScreenString;

- (BOOL) onDevicePackageReceived:(NetworkPackage*)np;
- (UIView*) getView:(UIViewController*)vc;
+ (PluginInfo*) getPluginInfo;

@end

#endif /* RunCommand_h */
