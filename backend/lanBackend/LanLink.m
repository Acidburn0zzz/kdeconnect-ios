//Copyright 27/4/14  YANG Qiao yangqiao0505@me.com
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
//----------------------------------------------------------------------

#import "LanLink.h"

#import "GCDAsyncSocket.h"
#import "SecKeyWrapper.h"
#define PAYLOAD_PORT 1739
#define PAYLOAD_SEND_DELAY 0 //ns

#import "X509CertificateHelper.h"

@interface LanLink()
{
    uint16_t _payloadPort;
    dispatch_queue_t _socketQueue;
}

@property(nonatomic) GCDAsyncSocket* _socket;
@property(nonatomic) NetworkPackage* _pendingPairNP;
@property(nonatomic) NSMutableArray* _pendingRSockets;
@property(nonatomic) NSMutableArray* _pendingLSockets;
@property(nonatomic) NSMutableArray* _pendingPayloadNP;
@property(nonatomic) NSMutableArray* _pendingPayloads;

@end

@implementation LanLink

@synthesize _deviceId;
@synthesize _linkDelegate;
@synthesize _pendingLSockets;
@synthesize _pendingPairNP;
@synthesize _pendingPayloadNP;
@synthesize _pendingPayloads;
@synthesize _pendingRSockets;
@synthesize _socket;

- (LanLink*) init:(GCDAsyncSocket*)socket deviceId:(NSString*) deviceid setDelegate:(id)linkdelegate
{
    if ([super init:deviceid setDelegate:linkdelegate])
    {
        _socket=socket;
        _deviceId=deviceid;
        _linkDelegate=linkdelegate;
        _pendingPairNP=nil;
        [_socket setDelegate:self];
        [_socket performBlock:^{
            [_socket enableBackgroundingOnSocket];
        }];
        //NSLog(@"LanLink:lanlink for device:%@ created",_deviceId);
        [_socket readDataToData:[GCDAsyncSocket LFData] withTimeout:-1 tag:PACKAGE_TAG_NORMAL];
        _pendingRSockets=[NSMutableArray arrayWithCapacity:1];
        _pendingLSockets=[NSMutableArray arrayWithCapacity:1];
        _pendingPayloadNP=[NSMutableArray arrayWithCapacity:1];
        _pendingPayloads=[NSMutableArray arrayWithCapacity:1];
        _payloadPort=PAYLOAD_PORT;
        _socketQueue=dispatch_queue_create("com.kde.org.kdeconnect.payload_socketQueue", NULL);
    }
    return self;
}

- (BOOL) sendPackage:(NetworkPackage *)np tag:(long)tag
{
    NSLog(@"llink send package");
    if (![_socket isConnected]) {
        NSLog(@"LanLink: Device:%@ disconnected",_deviceId);
        return false;
    }
    
    NSData* data=[np serialize];
    [_socket writeData:data withTimeout:-1 tag:tag];
    //TO-DO return true only when send successfully
    NSLog(@"%@", [NSString stringWithUTF8String:[data bytes]]);
    
    return true;
}

- (void) disconnect
{
    if ([_socket isConnected]) {
        [_socket disconnect];
    }
    if (_linkDelegate) {
        [_linkDelegate onLinkDestroyed:self];
    }
    _pendingPairNP=nil;
    NSLog(@"LanLink: Device:%@ disconnected",_deviceId);
}

#pragma mark TCP delegate
/**
 * Called when a socket accepts a connection.
 * Another socket is automatically spawned to handle it.
 *
 * You must retain the newSocket if you wish to handle the connection.
 * Otherwise the newSocket instance will be released and the spawned connection will be closed.
 *
 * By default the new socket will have the same delegate and delegateQueue.
 * You may, of course, change this at any time.
 **/
- (void)socket:(GCDAsyncSocket *)sock didAcceptNewSocket:(GCDAsyncSocket *)newSocket
{
    /* Start Server TLS */
    NSDictionary *tlsSettings = [[NSDictionary alloc] initWithObjectsAndKeys:
                                 (id)kCFStreamSocketSecurityLevelNegotiatedSSL, (id)kCFStreamSSLLevel,
                                 (id)kCFBooleanFalse, (id)kCFStreamSSLAllowsExpiredCertificates,
                                 (id)kCFBooleanFalse, (id)kCFStreamSSLAllowsExpiredRoots,
                                 (id)kCFBooleanTrue, (id)kCFStreamSSLAllowsAnyRoot,
                                 (id)kCFBooleanFalse, (id)kCFStreamSSLValidatesCertificateChain, nil];
    [newSocket startTLS: tlsSettings];
    NSLog(@"Start TLS");
    
    NSLog(@"Lanlink: didAcceptNewSocket");
    NSMutableArray* payloadArray;
    @synchronized(_pendingLSockets){
        //TO-DO should use a single sock for listing and send payload with newSocket
        NSUInteger index=[_pendingLSockets indexOfObject:sock];
        payloadArray=[_pendingPayloads objectAtIndex:index];
    }
    dispatch_time_t t = dispatch_time(DISPATCH_TIME_NOW,0);
    NSData* chunk=[payloadArray firstObject];
    if (!payloadArray|!chunk) {
        @synchronized(_pendingLSockets){
            NSUInteger index=[_pendingLSockets indexOfObject:sock];
            payloadArray=[_pendingPayloads objectAtIndex:index];
            [_pendingLSockets removeObject:sock];
            [_pendingPayloads removeObjectAtIndex:index];
        }
        return;
    }
    //TO-DO send the data chunk one by one in order to get the proccess percentage
    for (NSData* chunk in payloadArray) {
        t=dispatch_time(t, PAYLOAD_SEND_DELAY*NSEC_PER_MSEC);
        dispatch_after(t,_socketQueue, ^(void){
            [newSocket writeData:chunk withTimeout:-1 tag:PACKAGE_TAG_PAYLOAD];
        });
    }
}


/**
 * Called when a socket connects and is ready for reading and writing.
 * The host parameter will be an IP address, not a DNS name.
 **/

- (void)socket:(GCDAsyncSocket *)sock didConnectToHost:(NSString *)host port:(uint16_t)port
{
    NSLog(@"Lanlink did connect to payload host, begin recieving data");
    
    /* Start Client TLS */
    /*NSDictionary *tlsSettings = [[NSDictionary alloc] initWithObjectsAndKeys:
                                 (id)kCFStreamSocketSecurityLevelNegotiatedSSL, (id)kCFStreamSSLLevel,
                                 (id)kCFBooleanFalse, (id)kCFStreamSSLAllowsExpiredCertificates,
                                 (id)kCFBooleanFalse, (id)kCFStreamSSLAllowsExpiredRoots,
                                 (id)kCFBooleanTrue, (id)kCFStreamSSLAllowsAnyRoot,
                                 (id)kCFBooleanFalse, (id)kCFStreamSSLValidatesCertificateChain,
                                 nil];*/
    //[sock startTLS: tlsSettings];
    //NSLog(@"Start Client TLS");
    
    NetworkPackage *np = [NetworkPackage createIdentityPackage];
    NSData *data = [np serialize];
    
    [sock writeData:data withTimeout:0 tag:PACKAGE_TAG_IDENTITY];
    
    // @synchronized(_pendingRSockets){
    //    NSUInteger index=[_pendingRSockets indexOfObject:sock];
    //    [sock readDataToLength:[[_pendingPayloadNP objectAtIndex:index] _PayloadSize] withTimeout:-1 tag:PACKAGE_TAG_PAYLOAD];
    //}
}

/**
 * Called when a socket has completed reading the requested data into memory.
 * Not called if there is an error.
 **/
- (void)socket:(GCDAsyncSocket *)sock didReadData:(NSData *)data withTag:(long)tag
{
    if (tag==PACKAGE_TAG_PAYLOAD) {
        NetworkPackage* np;
        @synchronized(_pendingRSockets){
        NSUInteger index=[_pendingRSockets indexOfObject:sock];
        np=[_pendingPayloadNP objectAtIndex:index];
        [np set_Payload:data];
        }
        
        @synchronized(_pendingPayloadNP){
            [_pendingPayloadNP removeObject:np];
            [_pendingRSockets removeObject:sock];
        }
        [_linkDelegate onPackageReceived:np];
        return;
    }
    NSLog(@"llink did read data");
    //BUG even if we read with a seperator LFData , it's still possible to receive several data package together. So we split the string and retrieve the package
    [_socket readDataToData:[GCDAsyncSocket LFData] withTimeout:-1 tag:PACKAGE_TAG_NORMAL];
    NSString * jsonStr=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSLog(@"%@", jsonStr);
    NSArray* packageArray=[jsonStr componentsSeparatedByString:@"\n"];
    for (NSString* dataStr in packageArray) {
        NetworkPackage* np=[NetworkPackage unserialize:[dataStr dataUsingEncoding:NSUTF8StringEncoding]];
        if (_linkDelegate && np) {
            //NSLog(@"llink did read data:\n%@",dataStr);
            if ([[np _Type] isEqualToString:PACKAGE_TYPE_PAIR]) {
                _pendingPairNP=np;
            }
            if ([np _PayloadTransferInfo]) {
                GCDAsyncSocket* socket=[[GCDAsyncSocket alloc] initWithDelegate:self delegateQueue:_socketQueue];
                @synchronized(_pendingRSockets){
                    [_pendingRSockets addObject:socket];
                    [_pendingPayloadNP addObject:np];
                }
                NSError* error=nil;
                uint16_t tcpPort=[[[np _PayloadTransferInfo] valueForKey:@"port"] unsignedIntValue];
                if (![socket connectToHost:[sock connectedHost] onPort:tcpPort error:&error]){
                    NSLog(@"Lanlink connect to payload host failed");
                }
                return;
            }
            [_linkDelegate onPackageReceived:np];
        }
    }
}

/**
 * Called when a socket has completed writing the requested data. Not called if there is an error.
 **/
- (void)socket:(GCDAsyncSocket *)sock didWriteDataWithTag:(long)tag
{
    //NSLog(@"llink didWriteData");
    if (_linkDelegate) {
        [_linkDelegate onSendSuccess:tag];
    }
    if (tag==PACKAGE_TAG_PAYLOAD) {
        //NSLog(@"llink payload sendpk");
    }
    
}

/**
 * Called if a read operation has reached its timeout without completing.
 * This method allows you to optionally extend the timeout.
 * If you return a positive time interval (> 0) the read's timeout will be extended by the given amount.
 * If you don't implement this method, or return a non-positive time interval (<= 0) the read will timeout as usual.
 *
 * The elapsed parameter is the sum of the original timeout, plus any additions previously added via this method.
 * The length parameter is the number of bytes that have been read so far for the read operation.
 *
 * Note that this method may be called multiple times for a single read if you return positive numbers.
 **/
- (NSTimeInterval)socket:(GCDAsyncSocket *)sock shouldTimeoutReadWithTag:(long)tag
                 elapsed:(NSTimeInterval)elapsed
               bytesDone:(NSUInteger)length
{
    return 0;
}

/**
 * Called if a write operation has reached its timeout without completing.
 * This method allows you to optionally extend the timeout.
 * If you return a positive time interval (> 0) the write's timeout will be extended by the given amount.
 * If you don't implement this method, or return a non-positive time interval (<= 0) the write will timeout as usual.
 *
 * The elapsed parameter is the sum of the original timeout, plus any additions previously added via this method.
 * The length parameter is the number of bytes that have been written so far for the write operation.
 *
 * Note that this method may be called multiple times for a single write if you return positive numbers.
 **/
- (NSTimeInterval)socket:(GCDAsyncSocket *)sock shouldTimeoutWriteWithTag:(long)tag
                 elapsed:(NSTimeInterval)elapsed
               bytesDone:(NSUInteger)length
{
    return 0;
}

/**
 * Called when a socket disconnects with or without error.
 *
 * If you call the disconnect method, and the socket wasn't already disconnected,
 * then an invocation of this delegate method will be enqueued on the _socketQueue
 * before the disconnect method returns.
 *
 * Note: If the GCDAsyncSocket instance is deallocated while it is still connected,
 * and the delegate is not also deallocated, then this method will be invoked,
 * but the sock parameter will be nil. (It must necessarily be nil since it is no longer available.)
 * This is a generally rare, but is possible if one writes code like this:
 *
 * asyncSocket = nil; // I'm implicitly disconnecting the socket
 *
 * In this case it may preferrable to nil the delegate beforehand, like this:
 *
 * asyncSocket.delegate = nil; // Don't invoke my delegate method
 * asyncSocket = nil; // I'm implicitly disconnecting the socket
 *
 * Of course, this depends on how your state machine is configured.
 **/
- (void)socketDidDisconnect:(GCDAsyncSocket *)sock withError:(NSError *)err
{
    if ([_pendingRSockets containsObject:sock]) {
        //NSLog(@"llink payload socket disconnected");
        @synchronized(_pendingRSockets){
            NSUInteger index=[_pendingRSockets indexOfObject:sock];
            [_pendingRSockets removeObjectAtIndex:index];
            [_pendingPayloadNP removeObjectAtIndex:index];
        }
    }
    if (_linkDelegate&&(sock==_socket)) {
        //NSLog(@"llink socket did disconnect");
        [_linkDelegate onLinkDestroyed:self];
    }
    
}

/**
 * Called when a socket has written some data, but has not yet completed the entire write.
 * It may be used to for things such as updating progress bars.
 **/
- (void)socket:(GCDAsyncSocket *)sock didWritePartialDataOfLength:(NSUInteger)partialLength tag:(long)tag
{
    
}

- (void)socketDidSecure:(GCDAsyncSocket *)sock
{
    NSLog(@"Connection is secure");
}

- (void)socket:(GCDAsyncSocket *)sock didReceiveTrust:(SecTrustRef)trust completionHandler:(void (^)(BOOL shouldTrustPeer))completionHandler
{
    /*
    OSStatus status = -1;
    SecTrustResultType result = kSecTrustResultDeny;

    SecCertificateRef cert2UseRef = NULL;
    NSDictionary *queryCert = @{
        (id)kSecClass: (id)kSecClassCertificate,
        (id)kSecAttrLabel: @CERT_TAG,
        (id)kSecReturnRef:  (id)kCFBooleanTrue
    };
    OSStatus copyStatus = SecItemCopyMatching((CFDictionaryRef) queryCert, (CFTypeRef *) &cert2UseRef);
    if (copyStatus != errSecSuccess) {
        NSLog(@"Error get Certificate");
    } else {
        NSLog(@"Certificate OK, %@", cert2UseRef);
    }
    
    const void *ref[] = {cert2UseRef};
    CFArrayRef ary = CFArrayCreate(NULL, ref, 1, NULL);

    status = SecTrustSetAnchorCertificates(trust, ary);
    
    //SecTrustSetAnchorCertificates(trust, ary);
    //status = SecTrustSetAnchorCertificatesOnly(trust, YES);
    NSLog(@"TrustStatus: %d", status);
    
    status = SecTrustEvaluate(trust, &result);
    NSLog(@"TrustStatus: %d %u", status, result);

    if ((status == noErr && (result == kSecTrustResultProceed || result == kSecTrustResultUnspecified)))
    {*/
        completionHandler(YES);

        NSLog(@"Receive Certificate, Trust it");
    /*}
    else
    {
        CFArrayRef arrayRefTrust = SecTrustCopyProperties(trust);
        NSLog(@"error in connection occured\n%@", arrayRefTrust);

        completionHandler(YES);
    }*/
    /* TODO: Validate name */
    // completionHandler(YES);
}

- (BOOL)socketShouldManuallyEvaluateTrust:(GCDAsyncSocket *)sock
{
    NSLog(@"Should Evaluate Certificate");
    return YES;
}

- (BOOL)socket:(GCDAsyncSocket *)sock shouldTrustPeer:(SecTrustRef)trust
{
    NSLog(@"Trust Certificate from %@", [sock connectedHost]);
    return YES;
}

@end

