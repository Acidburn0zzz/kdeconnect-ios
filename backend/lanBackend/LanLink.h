//
//  LanLink.h
//  kdeconnect_test1
//
//  Created by yangqiao on 4/27/14.
//  Copyright (c) 2014 yangqiao. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "BaseLink.h"
#import "LanLinkProvider.h"
#import "AsyncSocket.h"
@class AsyncSocket;
@class LanLinkProvider;
@class BaseLink;
@class Device;
@interface LanLink : BaseLink
- (LanLink*) init:(AsyncSocket*)socket deviceId:(NSString*) deviceid provider:(BaseLinkProvider *)provider;
- (BOOL) sendPackage:(NetworkPackage *)np;
- (BOOL) sendPackageEncypted:(NetworkPackage *)np;
- (void) disconnect;
@end
