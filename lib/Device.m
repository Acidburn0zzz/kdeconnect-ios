//Copyright 29/4/14  YANG Qiao yangqiao0505@me.com
//kdeconnect is distributed under two licenses.
//
//* The Mozilla Public License (MPL) v2.0
//
//or
//
//* The General Public License (GPL) v2.1
//
//----------------------------------------------------------------------
//
//Software distributed under these licenses is distributed on an "AS
//IS" basis, WITHOUT WARRANTY OF ANY KIND, either express or
//implied. See the License for the specific language governing rights
//and limitations under the License.
//kdeconnect is distributed under both the GPL and the MPL. The MPL
//notice, reproduced below, covers the use of either of the licenses.
//
//---------------------------------------------------------------------

#import "Device.h"
#import "SettingsStore.h"
#import "IASKSettingsReader.h"
#define PAIR_TIMMER_TIMEOUT  10.0

@interface Device()
@property(nonatomic) NSMutableArray* _links;
@property(nonatomic) NSMutableDictionary* _plugins;
@property(nonatomic) NSMutableArray* _failedPlugins;
@end
@implementation Device

@synthesize _id;
@synthesize _name;
@synthesize _pairStatus;
@synthesize _protocolVersion;
@synthesize _type;
@synthesize _deviceDelegate;
@synthesize _links;
@synthesize _plugins;
@synthesize _failedPlugins;
@synthesize _supportedIncomingInterfaces;
@synthesize _supportedOutgoingInterfaces;

- (Device*) init:(NSString*)deviceId setDelegate:(id)deviceDelegate
{
    if ((self=[super init])) {
        _id=deviceId;
        if (isPhone) {
            _type=Phone;
        }
        if (isPad) {
            _type=Tablet;
        }
        _deviceDelegate=deviceDelegate;
        [self loadSetting];
        _links=[NSMutableArray arrayWithCapacity:1];
        _plugins=[NSMutableDictionary dictionaryWithCapacity:1];
        _failedPlugins=[NSMutableArray arrayWithCapacity:1];
    }
    return self;
}

- (Device*) init:(NetworkPackage*)np baselink:(BaseLink*)link setDelegate:(id)deviceDelegate
{
    if ((self=[super init])) {
        _id=[np objectForKey:@"deviceId"];
        _type=[Device Str2Devicetype:[np objectForKey:@"deviceType"]];
        _name=[np objectForKey:@"deviceName"];
        _supportedIncomingInterfaces=[np objectForKey:@"SupportedIncomingInterfaces"];
        _supportedOutgoingInterfaces=[np objectForKey:@"SupportedOutgoingInterfaces"];
        _links=[NSMutableArray arrayWithCapacity:1];
        _plugins=[NSMutableDictionary dictionaryWithCapacity:1];
        _failedPlugins=[NSMutableArray arrayWithCapacity:1];
        _protocolVersion=[np integerForKey:@"protocolVersion"];
        _deviceDelegate=deviceDelegate;
        [self addLink:np baseLink:link];
    }
    return self;
}

- (NSInteger) compareProtocolVersion
{
    return 0;
}

#pragma mark Link-related Functions

- (void) addLink:(NetworkPackage*)np baseLink:(BaseLink*)Link
{
    //NSLog(@"add link to %@",_id);
    if (_protocolVersion!=[np integerForKey:@"protocolVersion"]) {
        //NSLog(@"using different protocol version");
    }
    [_links addObject:Link];
    _id=[np objectForKey:@"deviceId"];
    _name=[np objectForKey:@"deviceName"];
    _type=[Device Str2Devicetype:[np objectForKey:@"deviceType"]];
    _supportedIncomingInterfaces=[[np objectForKey:@"SupportedIncomingInterfaces"] componentsSeparatedByString:@","];
    _supportedOutgoingInterfaces=[[np objectForKey:@"SupportedOutgoingInterfaces"] componentsSeparatedByString:@","];
    [self saveSetting];
    [Link set_linkDelegate:self];
    if ([_links count]==1) {
        //NSLog(@"one link available");
        if (_deviceDelegate) {
            [_deviceDelegate onDeviceReachableStatusChanged:self];
        }
    }
}

- (void) onLinkDestroyed:(BaseLink *)link
{
    //NSLog(@"device on link destroyed");
    [_links removeObject:link];
    //NSLog(@"remove link ; %lu remaining", (unsigned long)[_links count]);
    
    if ([_links count]==0) {
        //NSLog(@"no available link");
        if (_deviceDelegate) {
            [_deviceDelegate onDeviceReachableStatusChanged:self];
            [_plugins removeAllObjects];
            [_failedPlugins removeAllObjects];
        }
    }
    if (_deviceDelegate) {
        [_deviceDelegate onLinkDestroyed:link];
    }
}

- (BOOL) sendPackage:(NetworkPackage *)np tag:(long)tag
{
    //NSLog(@"device send package");
    if (![[np _Type] isEqualToString:PACKAGE_TYPE_PAIR]) {
        for (BaseLink* link in _links) {
            if ([link sendPackage:np tag:tag]) {
                return true;
            }
        }
    }
    else{
        for (BaseLink* link in _links) {
            if ([link sendPackage:np tag:tag]) {
                return true;
            }
        }
    }
    return false;
}

- (void) onSendSuccess:(long)tag
{
    //NSLog(@"device on send success");
    if (tag==PACKAGE_TAG_PAIR) {
        if (_pairStatus==RequestedByPeer) {
            [self setAsPaired];
        }
    }
    else{
        for (Plugin* plugin in [_plugins allValues]) {
//            [plugin sentPercentage:100 tag:tag];
        }
    }
}

- (void) onPackageReceived:(NetworkPackage*)np
{
    //NSLog(@"device on package received");
    if ([[np _Type] isEqualToString:PACKAGE_TYPE_PAIR]) {
        //NSLog(@"Pair package received");
        BOOL wantsPair=[np boolForKey:@"pair"];
        if (wantsPair==[self isPaired]) {
            //NSLog(@"already done, paired:%d",wantsPair);
            if (_pairStatus==Requested) {
                //NSLog(@"canceled by other peer");
                dispatch_async(dispatch_get_main_queue(), ^{
                    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(requestPairingTimeout:) object:nil];
                });
                _pairStatus=NotPaired;
                if (_deviceDelegate) {
                    [_deviceDelegate onDevicePairRejected:self];
                }
            }
            else if(wantsPair){
                [self acceptPairing];
            }
            return;
        }
        if (wantsPair) {
            //NSLog(@"pair request");
            if ((_pairStatus)==Requested) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(requestPairingTimeout:) object:nil];
                });
                [self setAsPaired];
            }
            else{
                _pairStatus=RequestedByPeer;
                if (_deviceDelegate) {
                    [_deviceDelegate onDevicePairRequest:self];
                }
            }
        }
        else{
            //NSLog(@"unpair request");
            PairStatus prevPairStatus=_pairStatus;
            _pairStatus=NotPaired;
            if (prevPairStatus==Requested) {
                //NSLog(@"canceled by other peer");
                dispatch_async(dispatch_get_main_queue(), ^{
                    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(requestPairingTimeout:) object:nil];
                });
            }else if (prevPairStatus==Paired){
                [self unpair];
            }
        }
    }else if ([self isPaired]){
        //NSLog(@"recieved a plugin package :%@",[np _Type]);
        for (Plugin* plugin in [_plugins allValues]) {
            [plugin onDevicePackageReceived:np];
        }
        
    }else{
        //NSLog(@"not paired, ignore packages, unpair the device");
        [self unpair];
    }
}

- (BOOL) isReachable
{
    return [_links count]!=0;
}

- (void) loadSetting
{
    //get app document path
    SettingsStore* _devSettings=[[SettingsStore alloc] initWithPath:_id];
    _name=[_devSettings objectForKey:@"name"];
    _type=[Device Str2Devicetype:[_devSettings objectForKey:@"type"]];
    _pairStatus=Paired;
    _protocolVersion=[_devSettings integerForKey:@"protocolVersion"];
    _supportedIncomingInterfaces=[_devSettings objectForKey:@"SupportedIncomingInterfaces"];
    _supportedOutgoingInterfaces=[_devSettings objectForKey:@"SupportedOutgoingInterfaces"];
}

- (void) saveSetting
{
    //get app document path
    SettingsStore* _devSettings=[[SettingsStore alloc] initWithPath:_id];
    [_devSettings setObject:_name forKey:@"name"];
    [_devSettings setObject:[Device Devicetype2Str:_type] forKey:@"type"];
    [_devSettings setInteger:_protocolVersion forKey:@"protocolVersion"];
    [_devSettings setObject:_supportedIncomingInterfaces forKey:@"SupportedIncomingInterfaces"];
    [_devSettings setObject:_supportedOutgoingInterfaces forKey:@"SupportedOutgoingInterfaces"];
    [_devSettings synchronize];
}

#pragma mark Pairing-related Functions
- (BOOL) isPaired
{
    return _pairStatus==Paired;
}

- (BOOL) isPaireRequested
{
    return _pairStatus==Requested;
}

- (void) setAsPaired
{
    _pairStatus=Paired;
    //NSLog(@"paired with %@",_name);
    [self saveSetting];
    if (_deviceDelegate) {
        [_deviceDelegate onDevicePairSuccess:self];
    }
    for (BaseLink* link in _links) {
    }
}

- (void) requestPairing
{
    if (![self isReachable]) {
        //NSLog(@"device failed:not reachable");
        return;
    }
    if (_pairStatus==Paired) {
        //NSLog(@"device failed:already paired");
        return;
    }
    if (_pairStatus==Requested) {
        //NSLog(@"device failed:already requested");
        return;
    }
    if (_pairStatus==RequestedByPeer) {
        //NSLog(@"device accept pair request");
    }
    else{
        //NSLog(@"device request pairing");
        _pairStatus=Requested;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self performSelector:@selector(requestPairingTimeout:) withObject:nil afterDelay:PAIR_TIMMER_TIMEOUT];
        });
    }
    NetworkPackage* np=[NetworkPackage createPairPackage];
    [self sendPackage:np tag:PACKAGE_TAG_PAIR];
}

- (void) requestPairingTimeout:(id)sender
{
    //NSLog(@"device request pairing timeout");
    if (_pairStatus==Requested) {
        _pairStatus=NotPaired;
        //NSLog(@"pairing timeout");
        if (_deviceDelegate) {
            [_deviceDelegate onDevicePairTimeout:self];
        }
        [self unpair];
    }
}

- (void) unpair
{
    //NSLog(@"device unpair");
    _pairStatus=NotPaired;
    NetworkPackage* np=[[NetworkPackage alloc] initWithType:PACKAGE_TYPE_PAIR];
    [np setBool:false forKey:@"pair"];
    [self sendPackage:np tag:PACKAGE_TAG_UNPAIR];
}

- (void) acceptPairing
{
    //NSLog(@"device accepted pair request");
    NetworkPackage* np=[NetworkPackage createPairPackage];
    [self sendPackage:np tag:PACKAGE_TAG_PAIR];
}

- (void) rejectPairing
{
    //NSLog(@"device rejected pair request ");
    [self unpair];
}

#pragma mark Plugins-related Functions
- (void) reloadPlugins
{
    if (![self isReachable]) {
        return;
    }
    //NSLog(@"device reload plugins");
    [_failedPlugins removeAllObjects];
    PluginFactory* pluginFactory=[PluginFactory sharedInstance];
    NSArray* pluginNames=[pluginFactory getAvailablePlugins];
    NSSortDescriptor *sd = [[NSSortDescriptor alloc] initWithKey:nil ascending:YES];
    pluginNames=[pluginNames sortedArrayUsingDescriptors:[NSArray arrayWithObject:sd]];
    SettingsStore* _devSettings=[[SettingsStore alloc] initWithPath:_id];
    for (NSString* pluginName in pluginNames) {
        if ([_devSettings objectForKey:pluginName]!=nil && ![_devSettings boolForKey:pluginName]) {
            [[_plugins objectForKey:pluginName] stop];
            [_plugins removeObjectForKey:pluginName];
            [_failedPlugins addObject:pluginName];
            continue;
        }
        [_plugins removeObjectForKey:pluginName];
        Plugin* plugin=[pluginFactory instantiatePluginForDevice:self pluginName:pluginName];
        if (plugin)
            [_plugins setValue:plugin forKey:pluginName];
        else
            [_failedPlugins addObject:pluginName];
    }
}

- (NSArray*) getPluginViews:(UIViewController*)vc
{
    NSMutableArray* views=[NSMutableArray arrayWithCapacity:1];
    for (Plugin* plugin in [_plugins allValues]) {
        UIView* view=[plugin getView:vc];
        if (view) {
            [views addObject:view];
        }
    }
    return views;
}

#pragma mark enum tools
+ (NSString*)Devicetype2Str:(DeviceType)type
{
    switch (type) {
        case Desktop:
            return @"desktop";
        case Laptop:
            return @"laptop";
        case Phone:
            return @"phone";
        case Tablet:
            return @"tablet";
        default:
            return @"unknown";
    }
}
+ (DeviceType)Str2Devicetype:(NSString*)str
{
    if ([str isEqualToString:@"desktop"]) {
        return Desktop;
    }
    if ([str isEqualToString:@"laptop"]) {
        return Laptop;
    }
    if ([str isEqualToString:@"phone"]) {
        return Phone;
    }
    if ([str isEqualToString:@"tablet"]) {
        return Tablet;
    }
    return Unknown;
}

@end












