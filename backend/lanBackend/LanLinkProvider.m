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

#import "LanLinkProvider.h"
#import "GCDAsyncUdpSocket.h"
#import "GCDAsyncSocket.h"
#import "NetworkPackage.h"
#import "SecKeyWrapper.h"

#import "X509CertificateHelper.h"
#import "CertificateUtils.h"

#import <Security/Security.h>
#import <Security/SecItem.h>
#import <Security/SecTrust.h>
#import <Security/CipherSuite.h>
#import <Security/SecIdentity.h>
#import <CommonCrypto/CommonDigest.h>
#import <CommonCrypto/CommonCryptor.h>

#import "Header.h"

@interface LanLinkProvider()
{
    uint16_t _tcpPort;
    dispatch_queue_t socketQueue;
}
@property(nonatomic) GCDAsyncUdpSocket* _udpSocket;
@property(nonatomic) GCDAsyncSocket* _tcpSocket;
@property(nonatomic) NSMutableArray* _pendingSockets;
@property(nonatomic) NSMutableArray* _pendingNps;
@property(nonatomic) SecCertificateRef _certificate;
//@property(nonatomic) NSString * _certificateRequestPEM;
@property(nonatomic) SecIdentityRef _identity;
@end

@implementation LanLinkProvider

@synthesize _connectedLinks;
@synthesize _linkProviderDelegate;
@synthesize _pendingNps;
@synthesize _pendingSockets;
@synthesize _tcpSocket;
@synthesize _udpSocket;
@synthesize _certificate;
//@synthesize _certificateRequestPEM;

- (LanLinkProvider*) initWithDelegate:(id)linkProviderDelegate
{
    if ([super initWithDelegate:linkProviderDelegate])
    {
        _tcpPort=MIN_TCP_PORT;
        [_tcpSocket disconnect];
        [_udpSocket close];
        _udpSocket=nil;
        _tcpSocket=nil;
        _pendingSockets=[NSMutableArray arrayWithCapacity:1];
        _pendingNps=[NSMutableArray arrayWithCapacity:1];
        _connectedLinks=[NSMutableDictionary dictionaryWithCapacity:1];
        _linkProviderDelegate=linkProviderDelegate;
        socketQueue=dispatch_queue_create("com.kde.org.kdeconnect.socketqueue", NULL);
    }
    
    //_certificate = [[SecKeyWrapper sharedWrapper] getCertificate];
    /*
     NSLog(@"Confirm Certificate: %@", _certificate);
    NSString *certificateRequestB64 = [_certificate base64EncodedStringWithOptions: 0];
    
    _certificateRequestPEM = [NSString stringWithFormat:@"-----BEGIN CERTIFICATE REQUEST-----\\n%@\\n-----END CERTIFICATE REQUEST-----\\n", certificateRequestB64];
     */
    return self;
}

- (void)setupSocket
{
    //NSLog(@"lp setup socket");
    NSError* err;
    _tcpSocket = [[GCDAsyncSocket alloc] initWithDelegate:self delegateQueue:socketQueue];
    _udpSocket = [[GCDAsyncUdpSocket alloc] initWithDelegate:self delegateQueue:socketQueue];
    if (![_udpSocket enableBroadcast:true error:&err]) {
        NSLog(@"udp listen broadcast error");
    }
    if (![_udpSocket bindToPort:UDP_PORT error:&err]) {
        NSLog(@"udp bind error");
    }
}

- (void)onStart
{
    NSLog(@"lp onstart");
    [self setupSocket];
    NSError* err;
    if (![_udpSocket beginReceiving:&err]) {
        NSLog(@"LanLinkProvider:UDP socket start error");
        return;
    }
    NSLog(@"LanLinkProvider:UDP socket start");
    if (![_tcpSocket isConnected]) {
        while (![_tcpSocket acceptOnPort:_tcpPort error:&err]) {
            _tcpPort++;
            if (_tcpPort > MAX_TCP_PORT) {
                _tcpPort = MIN_TCP_PORT;
            }
        }
    }
    
    NSLog(@"LanLinkProvider:setup tcp socket on port %d",_tcpPort);
    
    //Introduce myself , UDP broadcasting my id package
    NetworkPackage* np=[NetworkPackage createIdentityPackage];
    [np setInteger:_tcpPort forKey:@"tcpPort"];
    NSData* data=[np serialize];
    NSLog(@"sending:%@",[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
	[_udpSocket sendData:data  toHost:@"255.255.255.255" port:PORT withTimeout:-1 tag:UDPBROADCAST_TAG];
}

- (void)onStop
{
    //NSLog(@"lp onstop");
    [_udpSocket close];
    [_tcpSocket disconnect];
    for (GCDAsyncSocket* socket in _pendingSockets) {
        [socket disconnect];
    }
    for (LanLink* link in [_connectedLinks allValues]) {
        [link disconnect];
    }
    
    [_pendingNps removeAllObjects];
    [_pendingSockets removeAllObjects];
    [_connectedLinks removeAllObjects];
    _udpSocket=nil;
    _tcpSocket=nil;

}

- (void) onRefresh
{
    //NSLog(@"lp on refresh");
    if (![_tcpSocket isConnected]) {
        [self onNetworkChange];
        return;
    }
    if (![_udpSocket isClosed]) {
        NetworkPackage* np=[NetworkPackage createIdentityPackage];
        [np setInteger:_tcpPort forKey:@"tcpPort"];
        NSData* data=[np serialize];
        NSLog(@"sending:%@",[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
        [_udpSocket sendData:data toHost:@"255.255.255.255" port:PORT withTimeout:-1 tag:UDPBROADCAST_TAG];
    }
}

- (void)onNetworkChange
{
    NSLog(@"lp on networkchange");
    [self onStop];
    [self onStart];
}


- (void) onLinkDestroyed:(BaseLink*)link
{
    //NSLog(@"lp on linkdestroyed");
    if (link==[_connectedLinks objectForKey:[link _deviceId]]) {
        [_connectedLinks removeObjectForKey:[link _deviceId]];
    }
}

#pragma mark UDP Socket Delegate
/**
 * Called when the socket has received the requested datagram.
 **/

//a new device is introducing itself to me
- (void)udpSocket:(GCDAsyncUdpSocket *)sock didReceiveData:(NSData *)data fromAddress:(NSData *)address withFilterContext:(id)filterContext
{
    NSLog(@"lp receive udp package");
	NetworkPackage* np = [NetworkPackage unserialize:data];
    NSLog(@"linkprovider:received a udp package from %@",[np objectForKey:@"deviceName"]);
    //not id package
    
    if (![[np _Type] isEqualToString:PACKAGE_TYPE_IDENTITY]){
        NSLog(@"LanLinkProvider:expecting an id package");
        return;
    }
    
    //my own package
    NetworkPackage* np2=[NetworkPackage createIdentityPackage];
    NSString* myId=[[np2 _Body] valueForKey:@"deviceId"];
    if ([[np objectForKey:@"deviceId"] isEqualToString:myId]){
        NSLog(@"Ignore my own id package");
        return;
    }
    
    //deal with id package
    NSString* host;
    [GCDAsyncUdpSocket getHost:&host port:nil fromAddress:address];
    if ([host hasPrefix:@"::ffff:"]) {
        NSLog(@"Ignore packet");
        return;
    }
    
    NSLog(@"LanLinkProvider:id package received, creating link and a TCP connection socket");
    GCDAsyncSocket* socket=[[GCDAsyncSocket alloc] initWithDelegate:self delegateQueue:socketQueue];
    uint16_t tcpPort=[np integerForKey:@"tcpPort"];
    
    NSError* error=nil;
    if (![socket connectToHost:host onPort:tcpPort error:&error]) {
        NSLog(@"LanLinkProvider:tcp connection error");
        NSLog(@"try reverse connection");
        [[np2 _Body] setValue:[[NSNumber alloc ] initWithUnsignedInt:_tcpPort] forKey:@"tcpPort"];
        NSData* data=[np serialize];
        NSLog(@"%@",[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
        [_udpSocket sendData:data toHost:@"255.255.255.255" port:PORT withTimeout:-1 tag:UDPBROADCAST_TAG];
        return;
    }
    NSLog(@"connecting");
    
    //NetworkPackage *inp = [NetworkPackage createIdentityPackage];
    //NSData *inpData = [inp serialize];
    //[socket writeData:inpData withTimeout:0 tag:PACKAGE_TAG_IDENTITY];
    
    //add to pending connection list
    @synchronized(_pendingNps)
    {
        [_pendingSockets insertObject:socket atIndex:0];
        [_pendingNps insertObject:np atIndex:0];
    }
}

#pragma mark TCP Socket Delegate
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
	NSLog(@"TCP server: didAcceptNewSocket");
    [_pendingSockets addObject:newSocket];
    long index=[_pendingSockets indexOfObject:newSocket];
    //retrieve id package
    [newSocket readDataToData:[GCDAsyncSocket LFData] withTimeout:-1 tag:index];
}

/**
 * Called when a socket connects and is ready for reading and writing.
 * The host parameter will be an IP address, not a DNS name.
 **/

- (void)socket:(GCDAsyncSocket *)sock didConnectToHost:(NSString *)host port:(uint16_t)port
{
    [sock setDelegate:nil];
    NSLog(@"tcp socket didConnectToHost %@", host);
    
    
    //create LanLink and inform the background
    NSUInteger index=[_pendingSockets indexOfObject:sock];
    NetworkPackage* np=[_pendingNps objectAtIndex:index];
    NSString* deviceId=[np objectForKey:@"deviceId"];
    LanLink* oldlink;
    if ([[_connectedLinks allKeys] containsObject:deviceId]) {
        oldlink=[_connectedLinks objectForKey:deviceId];
    }
    
    LanLink* link=[[LanLink alloc] init:sock deviceId:[np objectForKey:@"deviceId"] setDelegate:nil];
    [_pendingSockets removeObject:sock];
    [_pendingNps removeObject:np];
    [_connectedLinks setObject:link forKey:[np objectForKey:@"deviceId"]];
    if (_linkProviderDelegate) {
        [_linkProviderDelegate onConnectionReceived:np link:link];
    }
    [oldlink disconnect];
    
    /* Start TLS */
    // NSMutableDictionary *settings = [[NSMutableDictionary alloc] init];
    // [settings setObject:[NSNumber numberWithBool:YES]
    //             forKey:GCDAsyncSocketManuallyEvaluateTrust];
    // [settings setObject: (id)kCFBooleanFalse forKey: (__bridge NSString *)kCFStreamSSLValidatesCertificateChain];
    // [sock startTLS: settings];
    // NSLog(@"Start TLS");
    
    SecIdentityRef identityRef = nil;
    CFArrayRef identityArray = NULL;
    
    // Retrieve a persistent reference to the identity consisting of the client certificate and the pre-existing private key
    NSDictionary *queryIdentity = @{
        (id)kSecClass: (id)kSecClassIdentity,
        (id)kSecReturnRef:  [NSNumber numberWithBool:YES],
        //(id)kSecReturnPersistentRef:  [NSNumber numberWithBool:YES],
        (id)kSecAttrLabel: @CERT_TAG/*,
        (id)kSecMatchLimit : (id)kSecMatchLimitAll*/
    };
    
    OSStatus copyStatus = SecItemCopyMatching((CFDictionaryRef) queryIdentity, (CFTypeRef *) &identityRef);
    //OSStatus copyStatus = SecItemCopyMatching((CFDictionaryRef) queryIdentity, (CFTypeRef *) &identityArray);
    if (copyStatus != errSecSuccess) {
        NSLog(@"Error get identity");
    } else {
        
        // Count of available names in ArrayRef
        /*CFIndex nameCount = CFArrayGetCount( identityArray );

        //Iterate through the CFArrayRef and fill the vector
        for( int i = 0; i < nameCount ; ++i  ) {
            SecIdentityRef identity = (SecIdentityRef)CFArrayGetValueAtIndex( identityArray, i );*/
            if (CFGetTypeID(identityRef) == SecIdentityGetTypeID()){
                NSLog(@"Identity Match %lu %lu\n", CFGetTypeID(identityRef), SecIdentityGetTypeID());
                //identityRef = identityRef;
                //break;
            } else {
                NSLog(@"Identity not match %lu %lu\n", CFGetTypeID(identityRef), SecIdentityGetTypeID());
            }
        //}
        
        //NSLog(@"Identity %@ %lu", identityRef, CFGetTypeID(_certificate));
    }
    
    SecCertificateRef cert2UseRef = NULL;
    NSDictionary *queryCert = @{
        (id)kSecClass: (id)kSecClassCertificate,
        (id)kSecAttrLabel: @CERT_TAG,
        (id)kSecReturnRef:  (id)kCFBooleanTrue
    };
    copyStatus = SecItemCopyMatching((CFDictionaryRef) queryCert, (CFTypeRef *) &cert2UseRef);
    if (copyStatus != errSecSuccess) {
        NSLog(@"Error get Certificate");
    } else {
        NSLog(@"Certificate OK, %@", cert2UseRef);
        NSLog(@"parseIncomingCerts: bad cert array (6) %lu %lu\n", SecCertificateGetTypeID(), CFGetTypeID(cert2UseRef));
    }
    NSLog(@"Peer name %@", deviceId);

    
    
    np=[NetworkPackage createIdentityPackage];
    [sock writeData:[np serialize] withTimeout:-1 tag:PACKAGE_TAG_IDENTITY];
    NSLog(@"End Send my identity package");
    
    /* Test with cert file */
    // NSURL *privateKeyFilePath = [[NSBundle mainBundle] URLForResource: @"privateKey" withExtension: @"pem"];
    // NSURL *certificateFilePath = [[NSBundle mainBundle] URLForResource: @"privateKey" withExtension: @"pem"];
    NSString *resourcePath = [[NSBundle mainBundle] pathForResource:@"rsaPrivate" ofType:@"p12"];
    NSData *p12Data = [NSData dataWithContentsOfFile:resourcePath];

    NSMutableDictionary * options = [[NSMutableDictionary alloc] init];

    SecKeyRef privateKeyRef = NULL;

    //change to the actual password you used here
    [options setObject:@"" forKey:(id)kSecImportExportPassphrase];

    CFArrayRef items = CFArrayCreate(NULL, 0, 0, NULL);

    OSStatus securityError = SecPKCS12Import((CFDataRef) p12Data,
                                             (CFDictionaryRef)options, &items);
    SecIdentityRef identityApp;
    if (securityError == noErr && CFArrayGetCount(items) > 0) {
        CFDictionaryRef identityDict = CFArrayGetValueAtIndex(items, 0);
        identityApp =
        (SecIdentityRef)CFDictionaryGetValue(identityDict,
                                             kSecImportItemIdentity);

        securityError = SecIdentityCopyPrivateKey(identityApp, &privateKeyRef);
        NSLog(@"Read OK");
        if (securityError != noErr) {
            privateKeyRef = NULL;
        }
    }
    //CFRelease(items);
    /* Test with cert file */
    
    NSArray *myCipherSuite = [[NSArray alloc] initWithObjects:
    [NSNumber numberWithInt: TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA256],
    [NSNumber numberWithInt: TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA384],
    [NSNumber numberWithInt: TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA],
    nil];
    NSArray *myCerts = [[NSArray alloc] initWithObjects:/*(__bridge id)identityRef, (__bridge id)cert2UseRef,*/ (__bridge id)identityApp, nil];
    NSDictionary *tlsSettings = [[NSDictionary alloc] initWithObjectsAndKeys:
        (id)GCDAsyncSocketSSLProtocolVersionMax, (id)[NSNumber numberWithInt: kTLSProtocol13],
        //(id)kCFBooleanFalse,       (id)kCFStreamSSLAllowsExpiredCertificates,  /* Disallowed expired certificate   */
        //(id)kCFBooleanFalse,       (id)kCFStreamSSLAllowsExpiredRoots,         /* Disallowed expired Roots CA      */
        //(id)kCFBooleanTrue,        (id)kCFStreamSSLAllowsAnyRoot,              /* Allow any root CA                */
        //(id)kCFBooleanFalse,       (id)kCFStreamSSLValidatesCertificateChain,  /* Do not validate all              */
        //(id)deviceId,              (id)kCFStreamSSLPeerName,                   /* Set peer name to the one we received */
        // (id)[[SecKeyWrapper sharedWrapper] getPrivateKeyRef], (id),
         //(id)kCFBooleanTrue,        (id)GCDAsyncSocketManuallyEvaluateTrust,
         (__bridge CFArrayRef) myCipherSuite, (id)GCDAsyncSocketSSLCipherSuites,
        (__bridge CFArrayRef) myCerts, (id)kCFStreamSSLCertificates,
        (id)[NSNumber numberWithInt:1],       (id)kCFStreamSSLIsServer,
    nil];
    NSLog(@"Start Server TLS");
    [sock startTLS:tlsSettings];
    
    // Start TLS
    /*
    NSDictionary *tlsSettings = [[NSDictionary alloc] initWithObjectsAndKeys:
                                 (id)kCFStreamSocketSecurityLevelNegotiatedSSL, (id)kCFStreamSSLLevel,
                                 (id)kCFBooleanFalse, (id)kCFStreamSSLAllowsExpiredCertificates,
                                 (id)kCFBooleanFalse, (id)kCFStreamSSLAllowsExpiredRoots,
                                 (id)kCFBooleanTrue, (id)kCFStreamSSLAllowsAnyRoot,
                                 (id)kCFBooleanFalse, (id)kCFStreamSSLValidatesCertificateChain,
                                 nil];
    [sock startTLS: tlsSettings];
    NSLog(@"Start Client TLS");
     */
    
    // Declare any Carbon variables we may create
    // We do this here so it's easier to compare to the bottom of this method where we release them all
    /*
     SecKeychainRef keychain = NULL;
    SecIdentitySearchRef searchRef = NULL;
    
    NSMutableArray *certificates = [[NSMutableArray alloc] init];
    
    SecKeychainCopyDefault(&keychain);
    SecIdentitySearchCreate(keychain, CSSM_KEYUSE_ANY, &searchRef);
    
    SecIdentityRef currentIdentityRef = NULL;
    while (searchRef && (SecIdentitySearchCopyNext(searchRef, &currentIdentityRef) != errSecItemNotFound)) {
        // Extract the private key from the identity, and examine it to see if it will work for us
        SecKeyRef privateKeyRef = NULL;
        SecIdentityCopyPrivateKey(currentIdentityRef, &privateKeyRef);
        
        if (privateKeyRef) {
            SecItemAttr itemAttributes[] = {kSecKeyPrintName};
            
            SecExternalFormat externalFormats[] = {kSecFormatUnknown};
            
            int itemAttributesSize  = sizeof(itemAttributes) / sizeof(*itemAttributes);
            int externalFormatsSize = sizeof(externalFormats) / sizeof(*externalFormats);
            NSAssert(itemAttributesSize == externalFormatsSize, @"Arrays must have identical counts!");
            
            SecKeychainAttributeInfo info = {itemAttributesSize, (void *)&itemAttributes, (void *)&externalFormats};
            
            SecKeychainAttributeList *privateKeyAttributeList = NULL;
            SecKeychainItemCopyAttributesAndData((SecKeychainItemRef)privateKeyRef,
                                                 &info, NULL, &privateKeyAttributeList, NULL, NULL);
            
            if (privateKeyAttributeList) {
//                SecKeychainAttribute nameAttribute = privateKeyAttributeList->attr[0];
                
//                NSString *name = [[[NSString alloc] initWithBytes:nameAttribute.data
//                                                           length:(nameAttribute.length)
//                                                         encoding:NSUTF8StringEncoding] autorelease];
                
                //                NSLog(@"name is %@", name);
                
                // Ugly Hack
                // For some reason, name sometimes contains odd characters at the end of it
                // I'm not sure why, and I don't know of a proper fix, thus the use of the hasPrefix: method
//                if ([name hasPrefix:@"eVue"])
//                {
                    // It's possible for there to be more than one private key with the above prefix
                    // But we're only allowed to have one identity, so we make sure to only add one to the array
                    if ([certificates count] == 0) {
                        [certificates addObject:(id)currentIdentityRef];
                    }
//                }
                
                SecKeychainItemFreeAttributesAndData(privateKeyAttributeList, NULL);
            }
            
            CFRelease(privateKeyRef);
        }
        
        CFRelease(currentIdentityRef);
    }
    
    if(keychain)  CFRelease(keychain);
    if(searchRef) CFRelease(searchRef);
    
    tls1 = [[NSDictionary alloc] initWithObjectsAndKeys:
            (id)kCFStreamSocketSecurityLevelNegotiatedSSL, (id)kCFStreamSSLLevel,
            certificates, (id)kCFStreamSSLCertificates,
            (id)kCFBooleanTrue, (id)kCFStreamSSLIsServer,
            nil];
    
    [certificates release];
     */
}

/**
 * Called when a socket has completed reading the requested data into memory.
 * Not called if there is an error.
 **/
- (void)socket:(GCDAsyncSocket *)sock didReadData:(NSData *)data withTag:(long)tag
{
    NSLog(@"lp tcp socket didReadData");
    NSLog(@"%@",[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
    NSString * jsonStr=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSArray* packageArray=[jsonStr componentsSeparatedByString:@"\n"];
    for (NSString* dataStr in packageArray) {
        if ([dataStr length] <= 0) continue;

        NetworkPackage* np=[NetworkPackage unserialize:[dataStr dataUsingEncoding:NSUTF8StringEncoding]];
        if (![[np _Type] isEqualToString:PACKAGE_TYPE_IDENTITY]) {
            NSLog(@"lp expecting an id package %@", [np _Type]);
            return;
        }
        NSString* deviceId=[np objectForKey:@"deviceId"];
        
        /*
         NSMutableDictionary *sslSettings = [[NSMutableDictionary alloc] init];
         NSData *pkcs12data = [[NSData alloc] initWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"client" ofType:@"bks"]];
         CFDataRef inPKCS12Data = (CFDataRef)CFBridgingRetain(pkcs12data);
         CFStringRef password = CFSTR("YOUR PASSWORD");
         const void *keys[] = { kSecImportExportPassphrase };
         const void *values[] = { password };
         CFDictionaryRef options = CFDictionaryCreate(NULL, keys, values, 1, NULL, NULL);

         CFArrayRef items = CFArrayCreate(NULL, 0, 0, NULL);

         OSStatus securityError = SecPKCS12Import(inPKCS12Data, options, &items);
         CFRelease(options);
         CFRelease(password);

         if(securityError == errSecSuccess)
             NSLog(@"Success opening p12 certificate.");

         CFDictionaryRef identityDict = CFArrayGetValueAtIndex(items, 0);
         SecIdentityRef myIdent = (SecIdentityRef)CFDictionaryGetValue(identityDict,
                                                                       kSecImportItemIdentity);

         SecIdentityRef  certArray[1] = { myIdent };
         CFArrayRef myCerts = CFArrayCreate(NULL, (void *)certArray, 1, NULL);

         [sslSettings setObject:(id)CFBridgingRelease(myCerts) forKey:(NSString *)kCFStreamSSLCertificates];
         [sslSettings setObject:NSStreamSocketSecurityLevelNegotiatedSSL forKey:(NSString *)kCFStreamSSLLevel];
         [sslSettings setObject:(id)kCFBooleanTrue forKey:(NSString *)kCFStreamSSLAllowsAnyRoot];
         [sslSettings setObject:@"CONNECTION ADDRESS" forKey:(NSString *)kCFStreamSSLPeerName];
         [sock startTLS:sslSettings];
         */
        
        //NSLog(@"PEM: %@", _certificateRequestPEM);
        
        //SecCertificateRef certificate = SecCertificateCreateWithData(kCFAllocatorMalloc, (__bridge CFDataRef)_certificate);
        // if (status != errSecSuccess) { NSLog(@"Error when generate identity"); }
        
        /*SecIdentityRef identity = NULL;
        //OSStatus copyStatus = SecIdentityCreateWithCertificate(NULL, certificate, &identity);
        
        NSMutableDictionary * identityAttr = [[NSMutableDictionary alloc] init];
        [identityAttr setObject:(id)kSecClassIdentity forKey:(id)kSecClass];
        OSStatus sanityCheck = SecItemCopyMatching((CFDictionaryRef) identityAttr, (CFTypeRef *)&identity);
        NSLog(@"Sanity Checkout %@ %@", sanityCheck == errSecItemNotFound ? @"errSecItemNotFound":@"Other", identity);
        
        NSString *pem = @"MIIDJDCCAgwCCQDXNZ5EcwJADzANBgkqhkiG9w0BAQsFADBUMQwwCgYDVQQKDANLREUxEzARBgNVBAsMCktERUNvbm5lY3QxLzAtBgNVBAMMJl9hMjBlNTc5YV9jMWQ1XzRkMDlfODQyYl80MjQ1ZTRkMTM3OGJfMB4XDTE5MDgyMjE3MjQwNloXDTI5MDgxOTE3MjQwNlowVDEMMAoGA1UECgwDS0RFMRMwEQYDVQQLDApLREVDb25uZWN0MS8wLQYDVQQDDCZfYTIwZTU3OWFfYzFkNV80ZDA5Xzg0MmJfNDI0NWU0ZDEzNzhiXzCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAOQYgkZ04F6kx6Tc1+4ZP3Rr0vPzvRnXY6WeYD9c1EkIjxl/9XkGBGQ2yTq5kzio0DtlTbAPR3l1FYED8qNMwC+WRLPCaS2UPQ9emuPFj07+Dg1qgFyOL3pT26RenQpTB4LjzeXz9KdDB8LLxpaJzNxKM7ls7UdkiDNU/bfwa+T9g62JhGUXtMJUiU0nVR4xEu6fh46QvpPvJ0CvBSbodv+NnnfNm2yzpDqBf0bIlFgUwN/RqoW3u/KsZXnfRMHwxcwYY+4z4cGkRZxjnjAk3j8xqaJi1FHXPw7ONddDuo82Qd/qEX1fU7ZVQWgC1aXte2W1xPU98nVw5cQO8a80yjkCAwEAATANBgkqhkiG9w0BAQsFAAOCAQEA3IFP7ideKNwNIZipd3wtkGBqGyr3WHwYGwzXoO/MooNToVZHzAcRQTZknqj6NvBgj8OpwxNkqUQJd0BIjQTxqDS9QCYlQ1QqngVvrCnE9SetgtTBsREj7Ki5LL9uurJUDJhq6mwk7x/+LLTmYURCvrr7bAgdzy2tyr5GNQOdDNy9TZxOH3ZeZ0uRf54qFTalu+3wDKSxsNvca/cLZiIv1H3Kvv8eP48vCnXQXaTuBKwKIjsqgppuzUqvAz4B5EEmyueZhM+KyhRB8yvaZcZI+LlgIps5zyi/t21gW6ha7lrcTA5NYUshrXwjjb5z936nX+cGhbFaE+P3H99PmnHB5Q==";

        // remove header, footer and newlines from pem string

        NSData *certData = [[NSData alloc] initWithBase64EncodedString: pem options: NSDataBase64DecodingIgnoreUnknownCharacters];
        
        NSLog(@"%@", certData);
        
        SecCertificateRef cert = SecCertificateCreateWithData(nil, (__bridge CFDataRef) certData);
        if( cert != NULL ) {
            CFStringRef certSummary = SecCertificateCopySubjectSummary(cert);
            NSString* summaryString = [[NSString alloc] initWithString:(__bridge NSString*)certSummary];
            NSLog(@"CERT SUMMARY: %@", summaryString);
            CFRelease(certSummary);
        } else {
            NSLog(@"1111 *** ERROR *** trying to create the SSL certificate from data, but failed");
        }*/
        
        //SecIdentityCreate(kCFAllocatorDefault, cert, [[SecKeyWrapper sharedWrapper] getPrivateKeyRef]);
        /*SecIdentityRef identityRef = nil;
        CFArrayRef identityArray = NULL;
        
        // Retrieve a persistent reference to the identity consisting of the client certificate and the pre-existing private key
        NSDictionary *queryIdentity = @{
            (id)kSecClass: (id)kSecClassIdentity,
            (id)kSecReturnRef:  [NSNumber numberWithBool:YES],
            //(id)kSecReturnPersistentRef:  [NSNumber numberWithBool:YES],
            (id)kSecAttrLabel: @CERT_TAG/*,
            (id)kSecMatchLimit : (id)kSecMatchLimitAll*/
        /*};
        
        OSStatus copyStatus = SecItemCopyMatching((CFDictionaryRef) queryIdentity, (CFTypeRef *) &identityRef);
        //OSStatus copyStatus = SecItemCopyMatching((CFDictionaryRef) queryIdentity, (CFTypeRef *) &identityArray);
        if (copyStatus != errSecSuccess) {
            NSLog(@"Error get identity");
        } else {
            
            // Count of available names in ArrayRef
            /*CFIndex nameCount = CFArrayGetCount( identityArray );

            //Iterate through the CFArrayRef and fill the vector
            for( int i = 0; i < nameCount ; ++i  ) {
                SecIdentityRef identity = (SecIdentityRef)CFArrayGetValueAtIndex( identityArray, i );*/
                /*if (CFGetTypeID(identityRef) == SecIdentityGetTypeID()){
                    NSLog(@"Identity Match %lu %lu\n", CFGetTypeID(identityRef), SecIdentityGetTypeID());
                    //identityRef = identityRef;
                    //break;
                } else {
                    NSLog(@"Identity not match %lu %lu\n", CFGetTypeID(identityRef), SecIdentityGetTypeID());
                }
            //}
            
            //NSLog(@"Identity %@ %lu", identityRef, CFGetTypeID(_certificate));
        }
        
        SecCertificateRef cert2UseRef = NULL;
        NSDictionary *queryCert = @{
            (id)kSecClass: (id)kSecClassCertificate,
            (id)kSecAttrLabel: @CERT_TAG,
            (id)kSecReturnRef:  (id)kCFBooleanTrue
        };
        copyStatus = SecItemCopyMatching((CFDictionaryRef) queryCert, (CFTypeRef *) &cert2UseRef);
        if (copyStatus != errSecSuccess) {
            NSLog(@"Error get Certificate");
        } else {
            NSLog(@"Certificate OK, %@", cert2UseRef);
            NSLog(@"parseIncomingCerts: bad cert array (6) %lu %lu\n", SecCertificateGetTypeID(), CFGetTypeID(cert2UseRef));
        }
        NSLog(@"Peer name %@", deviceId);*/
        
        /* Test with cert file */
        // NSURL *privateKeyFilePath = [[NSBundle mainBundle] URLForResource: @"privateKey" withExtension: @"pem"];
        // NSURL *certificateFilePath = [[NSBundle mainBundle] URLForResource: @"privateKey" withExtension: @"pem"];
        NSString *resourcePath = [[NSBundle mainBundle] pathForResource:@"rsaPrivate" ofType:@"p12"];
        NSData *p12Data = [NSData dataWithContentsOfFile:resourcePath];

        NSMutableDictionary * options = [[NSMutableDictionary alloc] init];

        SecKeyRef privateKeyRef = NULL;

        //change to the actual password you used here
        [options setObject:@"" forKey:(id)kSecImportExportPassphrase];

        CFArrayRef items = CFArrayCreate(NULL, 0, 0, NULL);

        OSStatus securityError = SecPKCS12Import((CFDataRef) p12Data,
                                                 (CFDictionaryRef)options, &items);
        SecIdentityRef identityApp;
        if (securityError == noErr && CFArrayGetCount(items) > 0) {
            CFDictionaryRef identityDict = CFArrayGetValueAtIndex(items, 0);
            identityApp =
            (SecIdentityRef)CFDictionaryGetValue(identityDict,
                                                 kSecImportItemIdentity);

            securityError = SecIdentityCopyPrivateKey(identityApp, &privateKeyRef);
            NSLog(@"Read OK");
            if (securityError != noErr) {
                privateKeyRef = NULL;
            }
        }
        //CFRelease(items);
        /* Test with cert file */
        
        // NSData *identityData = generateIdentityWithPrivateKey(@"5A2ED80EFBB74D1387901C061B596153",[[SecKeyWrapper sharedWrapper] getPrivateKeyBits]);
        CFArrayRef cfItems;
        NSArray *myCerts = [[NSArray alloc] initWithObjects:(__bridge id)identityApp, /*(__bridge id)cert2UseRef,*/ nil];
        
        /*NSLog(@"%@", _certificate);*/
        NSArray *myCipherSuite = [[NSArray alloc] initWithObjects:
                                  [[NSNumber alloc] initWithInt: TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA256],
                                  [[NSNumber alloc] initWithInt: TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA384],
                                  [[NSNumber alloc] initWithInt: TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA],
                                  nil];
        //NSArray *certs = [[NSArray alloc] initWithObjects:(__bridge id)identityRef, (__bridge id)caRef, nil];
        /* TLS */
        NSDictionary *tlsSettings = [[NSDictionary alloc] initWithObjectsAndKeys:
             //(id)kCFStreamSocketSecurityLevelNegotiatedSSL, (id)kCFStreamSSLLevel,
             //(id)kCFBooleanFalse,       (id)kCFStreamSSLAllowsExpiredCertificates,  /* Disallowed expired certificate   */
             //(id)kCFBooleanFalse,       (id)kCFStreamSSLAllowsExpiredRoots,         /* Disallowed expired Roots CA      */
             //(id)kCFBooleanTrue,        (id)kCFStreamSSLAllowsAnyRoot,              /* Allow any root CA                */
             //(id)kCFBooleanFalse,       (id)kCFStreamSSLValidatesCertificateChain,  /* Do not validate all              */
             (id)deviceId,              (id)kCFStreamSSLPeerName,                   /* Set peer name to the one we received */
             // (id)[[SecKeyWrapper sharedWrapper] getPrivateKeyRef], (id),
             //(id)kCFBooleanTrue,        (id)GCDAsyncSocketManuallyEvaluateTrust,
             (__bridge CFArrayRef) myCerts, (id)kCFStreamSSLCertificates,
             (__bridge CFArrayRef) myCipherSuite, (id)GCDAsyncSocketSSLCipherSuites,
             (id)[NSNumber numberWithInt:0],       (id)kCFStreamSSLIsServer,
             //(id)[NSNumber numberWithInt:kAlwaysAuthenticate], (id)GCDAsyncSocketSSLClientSideAuthenticate,
             (id)[NSNumber numberWithInt:1], (id)GCDAsyncSocketManuallyEvaluateTrust,
             nil];
        /*CFArrayRef certs = (__bridge CFArrayRef) myCerts;
        SecIdentityRef identity = (SecIdentityRef)CFArrayGetValueAtIndex(certs, 0);
        if (identity == NULL) {
            NSLog(@"parseIncomingCerts: bad cert array (1)\n");
        }
        if (CFGetTypeID(identity) != SecIdentityGetTypeID()) {
            NSLog(@"parseIncomingCerts: bad cert array (2) %lu %lu %lu %lu\n", CFGetTypeID(identity), CFGetTypeID(_certificate), CFGetTypeID(identityRef), SecIdentityGetTypeID());
        }
        //SecCertificateRef leafCert = (SecCertificateRef)CFArrayGetValueAtIndex(certs, 1);
        OSStatus ortn;// = SecIdentityCopyCertificate(identity, &leafCert);
        /*if (ortn) {
           NSLog(@"parseIncomingCerts: bad cert array (3)\n");
        }*/

        //SecKeyRef privKey = NULL;
        /* Fetch private key from identity */
        /*ortn = SecIdentityCopyPrivateKey(identity, &privKey);
        if (ortn) {
            NSLog(@"parseIncomingCerts: SecIdentityCopyPrivateKey err %d\n",
                        (int)ortn);
        }
        
        // SSLCopyBufferFromData(SecCertificateGetBytePtr(leafCert), SecCertificateGetLength(leafCert), &certChain[0].derCert);
        /*for (int ix = 1; ix < 2; ++ix) {
            SecCertificateRef intermediate =
            (SecCertificateRef)CFArrayGetValueAtIndex(certs, ix);
            if (intermediate == NULL) {
                NSLog(@"parseIncomingCerts: bad cert array (5)\n");
                ortn = errSecParam;
            }
            if (CFGetTypeID(intermediate) != SecCertificateGetTypeID()) {
                NSLog(@"parseIncomingCerts: bad cert array (6) %lu %lu\n", SecCertificateGetTypeID(), CFGetTypeID(intermediate));
                ortn = errSecParam;
            }

        }*/
        
        [sock startTLS: tlsSettings];
        NSLog(@"Start Client TLS");
        
        //CFRelease(identityRef);
        
        [sock setDelegate:nil];
        [_pendingSockets removeObject:sock];
        
        LanLink* oldlink;
        if ([[_connectedLinks allKeys] containsObject:deviceId]) {
            oldlink=[_connectedLinks objectForKey:deviceId];
        }
        //create LanLink and inform the background
        LanLink* link=[[LanLink alloc] init:sock deviceId:[np objectForKey:@"deviceId"] setDelegate:nil];
        [_connectedLinks setObject:link forKey:[np objectForKey:@"deviceId"]];
        if (_linkProviderDelegate) {
            [_linkProviderDelegate onConnectionReceived:np link:link];
        }
        [oldlink disconnect];
    }
    
}

/**
 * Called when a socket has completed writing the requested data. Not called if there is an error.
 **/
- (void)socket:(GCDAsyncSocket *)sock didWriteDataWithTag:(long)tag
{
    
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
 * then an invocation of this delegate method will be enqueued on the delegateQueue
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
    //NSLog(@"tcp socket did Disconnect");
    if (sock==_tcpSocket) {
        //NSLog(@"tcp server disconnected");
        _tcpSocket=nil;
    }
    else
    {
        [_pendingSockets removeObject:sock];
    }
}

- (BOOL)socketShouldManuallyEvaluateTrust:(GCDAsyncSocket *)sock
{
    NSLog(@"Should Evaluate Certificate LanLinkProvider");
    return YES;
}

- (BOOL)socket:(GCDAsyncSocket *)sock shouldTrustPeer:(SecTrustRef)trust
{
    NSLog(@"Trust Certificate from %@ LanLinkProvider", [sock connectedHost]);
    return YES;
}

- (void)socketDidSecure:(GCDAsyncSocket *)sock
{
    NSLog(@"Connection is secure LanLinkProvider");
    [sock setDelegate:nil];
    [_pendingSockets removeObject:sock];
    
    LanLink* oldlink;
    /*if ([[_connectedLinks allKeys] containsObject:deviceId]) {
        oldlink=[_connectedLinks objectForKey:deviceId];
    }*/
    //create LanLink and inform the background
    LanLink* link=[[LanLink alloc] init:sock deviceId:@"Test Object" setDelegate:nil];
    [_connectedLinks setObject:link forKey:@"Test Object"];
    //[oldlink disconnect];
}

- (void)socket:(GCDAsyncSocket *)sock didReceiveTrust:(SecTrustRef)trust completionHandler:(void (^)(BOOL shouldTrustPeer))completionHandler
{
    completionHandler(YES);

    NSLog(@"Receive Certificate, Trust it LanLinkProvider");
}


@end



























