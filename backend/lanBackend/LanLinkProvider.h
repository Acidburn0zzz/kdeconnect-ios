//
//  LanLinkProvider.h
//  kdeconnect_test1
//
//  Created by yangqiao on 4/27/14.
//  
//
#import <Foundation/Foundation.h>
#import "LanLink.h"
#import "BaseLinkProvider.h"

@interface LanLinkProvider : BaseLinkProvider <linkDelegate>

- (LanLinkProvider*) initWithDelegate:(id)linkProviderDelegate;
- (void) onStart;
- (void) onRefresh;
- (void) onStop;
- (void) onNetworkChange;
- (void) onLinkDestroyed:(BaseLink*)link;

@end
