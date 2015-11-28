//
//  ASIHTTPRequest.m
//
//  Created by Ben Copsey on 04/10/2007.
//  Copyright 2007-2011 All-Seeing Interactive. All rights reserved.
//
//  A guide to the main features is available at:
//  http://allseeing-i.com/ASIHTTPRequest
//
//  Portions are based on the ImageClient example from Apple:
//  See: http://developer.apple.com/samplecode/ImageClient/listing37.html

#import "ASIHTTPRequest.h"

#import <SystemConfiguration/SystemConfiguration.h>
#import "ASIInputStream.h"
#import "ASIDataDecompressor.h"

// Automatically set on build
NSString *ASIHTTPRequestVersion = @"v1.8.1-61 2011-09-19";

NSString* const NetworkRequestErrorDomain = @"ASIHTTPRequestErrorDomain";

static NSString *ASIHTTPRequestRunLoopMode = @"ASIHTTPRequestRunLoopMode";

static const CFOptionFlags kNetworkEvents =  kCFStreamEventHasBytesAvailable | kCFStreamEventEndEncountered | kCFStreamEventErrorOccurred;

// The default number of seconds to use for a timeout
static NSTimeInterval defaultTimeOutSeconds = 10;

static void ReadStreamClientCallBack(__unused CFReadStreamRef readStream, CFStreamEventType type, void *clientCallBackInfo) {
    [((ASIHTTPRequest*)clientCallBackInfo) handleNetworkEvent: type];
}

// This lock prevents the operation from being cancelled while it is trying to update the progress, and vice versa
static NSRecursiveLock *progressLock;

static NSError *ASIRequestCancelledError;
static NSError *ASIRequestTimedOutError;
static NSError *ASIAuthenticationError;
static NSError *ASIUnableToCreateRequestError;
static NSError *ASITooMuchRedirectionError;

static NSMutableArray *downloadBandwidthUsageTracker = nil;
static NSMutableArray *uploadBandwidthUsageTracker = nil;

static unsigned long averageDownloadBandwidthUsedPerSecond = 0;
static unsigned long averageUploadBandwidthUsedPerSecond = 0;

// These are used for queuing persistent connections on the same connection

// Incremented every time we specify we want a new connection
static unsigned int nextConnectionNumberToCreate = 0;

// An array of connectionInfo dictionaries.
// When attempting a persistent connection, we look here to try to find an existing connection to the same server that is currently not in use
static NSMutableArray *persistentConnectionsPool = nil;

// Mediates access to the persistent connections pool
static NSRecursiveLock *connectionsLock = nil;

// Each request gets a new id, we store this rather than a ref to the request itself in the connectionInfo dictionary.
// We do this so we don't have to keep the request around while we wait for the connection to expire
static unsigned int nextRequestID = 0;

// Records how much bandwidth all requests combined have used in the last second
static unsigned long downloadBandwidthUsedInLastSecond = 0;
static unsigned long uploadBandwidthUsedInLastSecond = 0;

// A date one second in the future from the time it was created
static NSDate *downloadBandwidthMeasurementDate = nil;
static NSDate *uploadBandwidthMeasurementDate = nil;

// Since throttling variables are shared among all requests, we'll use a lock to mediate access
static NSLock *downloadBandwidthThrottlingLock = nil;
static NSLock *uploadBandwidthThrottlingLock = nil;

// the maximum number of bytes that can be transmitted in one second
static unsigned long maxDownloadBandwidthPerSecond = 0;
static unsigned long maxUploadBandwidthPerSecond = 0;

// When throttling bandwidth, Set to a date in future that we will allow all requests to wake up and reschedule their streams
static NSDate *downloadThrottleWakeUpTime = nil;
static NSDate *uploadThrottleWakeUpTime = nil;

// Used for tracking when requests are using the network
static unsigned int runningRequestCount = 0;

// The thread all requests will run on
// Hangs around forever, but will be blocked unless there are requests underway
static NSThread *networkThread = nil;

static NSOperationQueue *sharedQueue = nil;

// Private stuff
@interface ASIHTTPRequest ()

- (void)cancelLoad;

- (void)destroyReadStream;
- (void)scheduleReadStream;
- (void)unscheduleReadStream;

+ (void)measureDownloadBandwidthUsage;
+ (void)measureUploadBandwidthUsage;
+ (void)recordDownloadBandwidthUsage;
+ (void)recordUploadBandwidthUsage;

- (void)startRequest;
- (void)updateStatus:(NSTimer *)timer;
- (void)checkRequestStatus;
- (void)reportFailure;
- (void)reportFinished;
- (void)markAsFinished;
- (BOOL)shouldTimeOut;

+ (void)performInvocation:(NSInvocation *)invocation onTarget:(id *)target releasingObject:(id)objectToRelease;
+ (void)runRequests;

// Called to update the size of a partial download when starting a request, or retrying after a timeout
- (void)updatePartialDownloadSize;

- (void)performBlockOnMainThread:(ASIBasicBlock)block;
- (void)releaseBlocksOnMainThread;
+ (void)releaseBlocks:(NSArray *)blocks;
- (void)callBlock:(ASIBasicBlock)block;

@property (assign) BOOL complete;
@property (retain) NSArray *responseCookies;
@property (assign) int responseStatusCode;
@property (retain, nonatomic) NSDate *lastActivityTime;

@property (assign) unsigned long long partialDownloadSize;
@property (assign, nonatomic) unsigned long long uploadBufferSize;
@property (retain, nonatomic) NSOutputStream *postBodyWriteStream;
@property (retain, nonatomic) NSInputStream *postBodyReadStream;
@property (assign, nonatomic) unsigned long long lastBytesRead;
@property (assign, nonatomic) unsigned long long lastBytesSent;
@property (atomic, retain) NSRecursiveLock *cancelledLock;
@property (retain, nonatomic) NSOutputStream *fileDownloadOutputStream;
@property (retain, nonatomic) NSOutputStream *inflatedFileDownloadOutputStream;
@property (assign, nonatomic) BOOL updatedProgress;
@property (retain, nonatomic) NSData *compressedPostBody;
@property (retain, nonatomic) NSString *compressedPostBodyFilePath;
@property (retain) NSString *responseStatusMessage;
@property (assign) BOOL inProgress;
@property (assign) int retryCount;
@property (assign) BOOL connectionCanBeReused;
@property (retain, nonatomic) NSMutableDictionary *connectionInfo;
@property (retain, nonatomic) NSInputStream *readStream;
@property (assign, nonatomic) BOOL readStreamIsScheduled;
@property (assign, nonatomic) BOOL downloadComplete;
@property (retain) NSNumber *requestID;
@property (assign, nonatomic) NSString *runLoopMode;
@property (retain, nonatomic) NSTimer *statusTimer;

@property (assign, nonatomic, setter=setSynchronous:) BOOL isSynchronous;
@end


@implementation ASIHTTPRequest

#pragma mark init / dealloc

+ (void)initialize
{
	if (self == [ASIHTTPRequest class]) {
		persistentConnectionsPool = [[NSMutableArray alloc] init];
		connectionsLock = [[NSRecursiveLock alloc] init];
		progressLock = [[NSRecursiveLock alloc] init];
		downloadBandwidthThrottlingLock = [[NSLock alloc] init];
        uploadBandwidthThrottlingLock = [[NSLock alloc] init];
		downloadBandwidthUsageTracker = [[NSMutableArray alloc] initWithCapacity:5];
        uploadBandwidthUsageTracker = [[NSMutableArray alloc] initWithCapacity:10];
		ASIRequestTimedOutError = [[NSError alloc] initWithDomain:NetworkRequestErrorDomain code:ASIRequestTimedOutErrorType userInfo:[NSDictionary dictionaryWithObjectsAndKeys:@"The request timed out",NSLocalizedDescriptionKey,nil]];
		ASIAuthenticationError = [[NSError alloc] initWithDomain:NetworkRequestErrorDomain code:ASIAuthenticationErrorType userInfo:[NSDictionary dictionaryWithObjectsAndKeys:@"Authentication needed",NSLocalizedDescriptionKey,nil]];
		ASIRequestCancelledError = [[NSError alloc] initWithDomain:NetworkRequestErrorDomain code:ASIRequestCancelledErrorType userInfo:[NSDictionary dictionaryWithObjectsAndKeys:@"The request was cancelled",NSLocalizedDescriptionKey,nil]];
		ASIUnableToCreateRequestError = [[NSError alloc] initWithDomain:NetworkRequestErrorDomain code:ASIUnableToCreateRequestErrorType userInfo:[NSDictionary dictionaryWithObjectsAndKeys:@"Unable to create request (bad url?)",NSLocalizedDescriptionKey,nil]];
		ASITooMuchRedirectionError = [[NSError alloc] initWithDomain:NetworkRequestErrorDomain code:ASITooMuchRedirectionErrorType userInfo:[NSDictionary dictionaryWithObjectsAndKeys:@"The request failed because it redirected too many times",NSLocalizedDescriptionKey,nil]];
		sharedQueue = [[NSOperationQueue alloc] init];
		[sharedQueue setMaxConcurrentOperationCount:4];

	}
}


- (id)initWithURL:(NSURL *)newURL
{
	self = [self init];
	[self setRequestMethod:@"GET"];

	[self setRunLoopMode:NSDefaultRunLoopMode];
	[self setShouldAttemptPersistentConnection:YES];
	[self setPersistentConnectionTimeoutSeconds:60.0];
	[self setShouldResetDownloadProgress:YES];
	[self setShouldResetUploadProgress:YES];
	[self setAllowCompressedResponse:YES];
	[self setShouldWaitToInflateCompressedResponses:YES];

	[self setTimeOutSeconds:[ASIHTTPRequest defaultTimeOutSeconds]];
	[self setValidatesSecureCertificate:YES];
	[self setDidStartSelector:@selector(requestStarted:)];
	[self setDidReceiveResponseHeadersSelector:@selector(request:didReceiveResponseHeaders:)];
	[self setDidFinishSelector:@selector(requestFinished:)];
	[self setDidFailSelector:@selector(requestFailed:)];
	[self setDidReceiveDataSelector:@selector(request:didReceiveData:)];
	[self setURL:newURL];
	[self setCancelledLock:[[[NSRecursiveLock alloc] init] autorelease]];
	return self;
}

+ (id)requestWithURL:(NSURL *)newURL
{
	return [[[self alloc] initWithURL:newURL] autorelease];
}

- (void)dealloc
{
	if (request) {
		CFRelease(request);
	}
	if (clientCertificateIdentity) {
		CFRelease(clientCertificateIdentity);
	}
	[self cancelLoad];
	[statusTimer invalidate];
	[statusTimer release];
	[queue release];
	[postBody release];
	[compressedPostBody release];
	[error release];
	[requestHeaders release];
	[requestCookies release];
	[downloadDestinationPath release];
	[temporaryFileDownloadPath release];
	[temporaryUncompressedDataDownloadPath release];
	[fileDownloadOutputStream release];
	[inflatedFileDownloadOutputStream release];
	[url release];
	[lastActivityTime release];
	[rawResponseData release];
	[responseHeaders release];
	[requestMethod release];
	[cancelledLock release];
	[postBodyFilePath release];
	[compressedPostBodyFilePath release];
	[postBodyWriteStream release];
	[postBodyReadStream release];
	[clientCertificates release];
	[responseStatusMessage release];
	[connectionInfo release];
	[requestID release];
	[dataDecompressor release];

	[self releaseBlocksOnMainThread];

	[super dealloc];
}

- (void)releaseBlocksOnMainThread
{
	NSMutableArray *blocks = [NSMutableArray array];
	if (completionBlock) {
		[blocks addObject:completionBlock];
		[completionBlock release];
		completionBlock = nil;
	}
	if (failureBlock) {
		[blocks addObject:failureBlock];
		[failureBlock release];
		failureBlock = nil;
	}
	if (startedBlock) {
		[blocks addObject:startedBlock];
		[startedBlock release];
		startedBlock = nil;
	}
	if (headersReceivedBlock) {
		[blocks addObject:headersReceivedBlock];
		[headersReceivedBlock release];
		headersReceivedBlock = nil;
	}
	if (bytesReceivedBlock) {
		[blocks addObject:bytesReceivedBlock];
		[bytesReceivedBlock release];
		bytesReceivedBlock = nil;
	}
	if (bytesSentBlock) {
		[blocks addObject:bytesSentBlock];
		[bytesSentBlock release];
		bytesSentBlock = nil;
	}
	if (downloadSizeIncrementedBlock) {
		[blocks addObject:downloadSizeIncrementedBlock];
		[downloadSizeIncrementedBlock release];
		downloadSizeIncrementedBlock = nil;
	}
	if (uploadSizeIncrementedBlock) {
		[blocks addObject:uploadSizeIncrementedBlock];
		[uploadSizeIncrementedBlock release];
		uploadSizeIncrementedBlock = nil;
	}
	if (dataReceivedBlock) {
		[blocks addObject:dataReceivedBlock];
		[dataReceivedBlock release];
		dataReceivedBlock = nil;
	}
	if (authenticationNeededBlock) {
		[blocks addObject:authenticationNeededBlock];
		[authenticationNeededBlock release];
		authenticationNeededBlock = nil;
	}
	[[self class] performSelectorOnMainThread:@selector(releaseBlocks:) withObject:blocks waitUntilDone:[NSThread isMainThread]];
}

// Always called on main thread
+ (void)releaseBlocks:(__unused NSArray *)blocks
{
	// Blocks will be released when this method exits
}


#pragma mark setup request

- (void)addRequestHeader:(NSString *)header value:(NSString *)value
{
	if (!requestHeaders) {
		[self setRequestHeaders:[NSMutableDictionary dictionaryWithCapacity:1]];
	}
	[requestHeaders setObject:value forKey:header];
}

// This function will be called either just before a request starts, or when postLength is needed, whichever comes first
// postLength must be set by the time this function is complete
- (void)buildPostBody
{
	if ([self haveBuiltPostBody]) {
		return;
	}
	
	// Are we submitting the request body from a file on disk
	if ([self postBodyFilePath]) {
		
		// If we were writing to the post body via appendPostData or appendPostDataFromFile, close the write stream
		if ([self postBodyWriteStream]) {
			[[self postBodyWriteStream] close];
			[self setPostBodyWriteStream:nil];
		}

		
		NSString *path;
        path = [self postBodyFilePath];
		NSError *err = nil;
		[self setPostLength:[[[[[NSFileManager alloc] init] autorelease] attributesOfItemAtPath:path error:&err] fileSize]];
		if (err) {
			[self failWithError:[NSError errorWithDomain:NetworkRequestErrorDomain code:ASIFileManagementError userInfo:[NSDictionary dictionaryWithObjectsAndKeys:[NSString stringWithFormat:@"Failed to get attributes for file at path '%@'",path],NSLocalizedDescriptionKey,error,NSUnderlyingErrorKey,nil]]];
			return;
		}
		
	// Otherwise, we have an in-memory request body
	} else {
        [self setPostLength:[[self postBody] length]];
	}
		
	if ([self postLength] > 0) {
		if ([requestMethod isEqualToString:@"GET"] || [requestMethod isEqualToString:@"DELETE"] || [requestMethod isEqualToString:@"HEAD"]) {
			[self setRequestMethod:@"POST"];
		}
		[self addRequestHeader:@"Content-Length" value:[NSString stringWithFormat:@"%llu",[self postLength]]];
	}
	[self setHaveBuiltPostBody:YES];

}

// Sets up storage for the post body
- (void)setupPostBody
{
	if ([self shouldStreamPostDataFromDisk]) {
		if (![self postBodyFilePath]) {
			[self setPostBodyFilePath:[NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]]];
			[self setDidCreateTemporaryPostDataFile:YES];
		}
		if (![self postBodyWriteStream]) {
			[self setPostBodyWriteStream:[[[NSOutputStream alloc] initToFileAtPath:[self postBodyFilePath] append:NO] autorelease]];
			[[self postBodyWriteStream] open];
		}
	} else {
		if (![self postBody]) {
			[self setPostBody:[[[NSMutableData alloc] init] autorelease]];
		}
	}	
}

- (void)appendPostData:(NSData *)data
{
	[self setupPostBody];
	if ([data length] == 0) {
		return;
	}
	if ([self shouldStreamPostDataFromDisk]) {
		[[self postBodyWriteStream] write:[data bytes] maxLength:[data length]];
	} else {
		[[self postBody] appendData:data];
	}
}

- (void)appendPostDataFromFile:(NSString *)file
{
	[self setupPostBody];
	NSInputStream *stream = [[[NSInputStream alloc] initWithFileAtPath:file] autorelease];
	[stream open];
	while ([stream hasBytesAvailable]) {
		
		unsigned char buffer[1024*256];
		NSInteger bytesRead = [stream read:buffer maxLength:sizeof(buffer)];
		if (bytesRead == 0) {
			// 0 indicates that the end of the buffer was reached.
			break;
		} else if (bytesRead < 0) {
			// A negative number means that the operation failed.
			break;
		}
		if ([self shouldStreamPostDataFromDisk]) {
			[[self postBodyWriteStream] write:buffer maxLength:(NSUInteger)bytesRead];
		} else {
			[[self postBody] appendData:[NSData dataWithBytes:buffer length:(NSUInteger)bytesRead]];
		}
	}
	[stream close];
}

- (NSString *)requestMethod
{
	[[self cancelledLock] lock];
	NSString *m = requestMethod;
	[[self cancelledLock] unlock];
	return m;
}

- (void)setRequestMethod:(NSString *)newRequestMethod
{
	[[self cancelledLock] lock];
	if (requestMethod != newRequestMethod) {
		[requestMethod release];
		requestMethod = [newRequestMethod retain];
		if ([requestMethod isEqualToString:@"POST"] || [requestMethod isEqualToString:@"PUT"] || [postBody length] || postBodyFilePath) {
			[self setShouldAttemptPersistentConnection:NO];
		}
	}
	[[self cancelledLock] unlock];
}

- (NSURL *)url
{
	[[self cancelledLock] lock];
	NSURL *u = url;
	[[self cancelledLock] unlock];
	return u;
}


- (void)setURL:(NSURL *)newURL
{
	[[self cancelledLock] lock];
	if ([newURL isEqual:[self url]]) {
		[[self cancelledLock] unlock];
		return;
	}
	[url release];
	url = [newURL retain];
	if (requestAuthentication) {
		CFRelease(requestAuthentication);
		requestAuthentication = NULL;
	}
	if (request) {
		CFRelease(request);
		request = NULL;
	}
	[[self cancelledLock] unlock];
}

- (id)delegate
{
	[[self cancelledLock] lock];
	id d = delegate;
	[[self cancelledLock] unlock];
	return d;
}

- (void)setDelegate:(id)newDelegate
{
	[[self cancelledLock] lock];
	delegate = newDelegate;
	[[self cancelledLock] unlock];
}

- (id)queue
{
	[[self cancelledLock] lock];
	id q = queue;
	[[self cancelledLock] unlock];
	return q;
}


- (void)setQueue:(id)newQueue
{
	[[self cancelledLock] lock];
	if (newQueue != queue) {
		[queue release];
		queue = [newQueue retain];
	}
	[[self cancelledLock] unlock];
}

#pragma mark get information about this request

// cancel the request - this must be run on the same thread as the request is running on
- (void)cancelOnRequestThread
{
	#if DEBUG_REQUEST_STATUS
	ASI_DEBUG_LOG(@"[STATUS] Request cancelled: %@",self);
	#endif
    
	[[self cancelledLock] lock];

    if ([self isCancelled] || [self complete]) {
		[[self cancelledLock] unlock];
		return;
	}
	[self failWithError:ASIRequestCancelledError];
	[self setComplete:YES];
	[self cancelLoad];
	
	CFRetain(self);
    [self willChangeValueForKey:@"isCancelled"];
    cancelled = YES;
    [self didChangeValueForKey:@"isCancelled"];
    
	[[self cancelledLock] unlock];
	CFRelease(self);
}

- (void)cancel
{
    [self performSelector:@selector(cancelOnRequestThread) onThread:[[self class] threadForRequest:self] withObject:nil waitUntilDone:NO];    
}

- (void)clearDelegatesAndCancel
{
	[[self cancelledLock] lock];

	// Clear delegates
	[self setDelegate:nil];
	[self setQueue:nil];
	[self setDownloadProgressDelegate:nil];
	[self setUploadProgressDelegate:nil];

	#if NS_BLOCKS_AVAILABLE
	// Clear blocks
	[self releaseBlocksOnMainThread];
	#endif

	[[self cancelledLock] unlock];
	[self cancel];
}


- (BOOL)isCancelled
{
    BOOL result;
    
	[[self cancelledLock] lock];
    result = cancelled;
    [[self cancelledLock] unlock];
    
    return result;
}

- (BOOL)isResponseCompressed
{
	NSString *encoding = [[self responseHeaders] objectForKey:@"Content-Encoding"];
	return encoding && [encoding rangeOfString:@"gzip"].location != NSNotFound;
}

- (NSData *)responseData
{	
	if ([self isResponseCompressed] && [self shouldWaitToInflateCompressedResponses]) {
		return [ASIDataDecompressor uncompressData:[self rawResponseData] error:NULL];
	} else {
		return [self rawResponseData];
	}
	return nil;
}

#pragma mark running a request

- (void)startSynchronous
{
#if DEBUG_REQUEST_STATUS || DEBUG_THROTTLING
	ASI_DEBUG_LOG(@"[STATUS] Starting synchronous request %@",self);
#endif
	[self setSynchronous:YES];
	[self setRunLoopMode:ASIHTTPRequestRunLoopMode];
	[self setInProgress:YES];

	if (![self isCancelled] && ![self complete]) {
		[self main];
		while (!complete) {
			[[NSRunLoop currentRunLoop] runMode:[self runLoopMode] beforeDate:[NSDate distantFuture]];
		}
	}

	[self setInProgress:NO];
}

- (void)start
{
	[self setInProgress:YES];
	[self performSelector:@selector(main) onThread:[[self class] threadForRequest:self] withObject:nil waitUntilDone:NO];
}

- (void)startAsynchronous
{
#if DEBUG_REQUEST_STATUS || DEBUG_THROTTLING
	ASI_DEBUG_LOG(@"[STATUS] Starting asynchronous request %@",self);
#endif
	[sharedQueue addOperation:self];
}

#pragma mark concurrency

- (BOOL)isConcurrent
{
    return YES;
}

- (BOOL)isFinished 
{
	return finished;
}

- (BOOL)isExecuting {
	return [self inProgress];
}

#pragma mark request logic

// Create the request
- (void)main
{
	@try {
		
		[[self cancelledLock] lock];

		// A HEAD request generated by an ASINetworkQueue may have set the error already. If so, we should not proceed.
		if ([self error]) {
			[self setComplete:YES];
			[self markAsFinished];
			return;		
		}

		[self setComplete:NO];

		if (![self url]) {
			[self failWithError:ASIUnableToCreateRequestError];
			return;		
		}
		
		// Must call before we create the request so that the request method can be set if needs be
		if (![self mainRequest]) {
			[self buildPostBody];
		}
		
		// If we're redirecting, we'll already have a CFHTTPMessageRef
		if (request) {
			CFRelease(request);
		}

		// Create a new HTTP request.
		request = CFHTTPMessageCreateRequest(kCFAllocatorDefault, (CFStringRef)[self requestMethod], (CFURLRef)[self url], kCFHTTPVersion1_1);
		if (!request) {
			[self failWithError:ASIUnableToCreateRequestError];
			return;
		}

		//If this is a HEAD request generated by an ASINetworkQueue, we need to let the main request generate its headers first so we can use them
		if ([self mainRequest]) {
			[[self mainRequest] buildRequestHeaders];
		}
		
		// Even if this is a HEAD request with a mainRequest, we still need to call to give subclasses a chance to add their own to HEAD requests (ASIS3Request does this)
		[self buildRequestHeaders];

		NSString *header;
		for (header in [self requestHeaders]) {
			CFHTTPMessageSetHeaderFieldValue(request, (CFStringRef)header, (CFStringRef)[[self requestHeaders] objectForKey:header]);
		}

        [self startRequest];

	} @catch (NSException *exception) {
		NSError *underlyingError = [NSError errorWithDomain:NetworkRequestErrorDomain code:ASIUnhandledExceptionError userInfo:[exception userInfo]];
        NSLog(@"FAILURE1 %@", underlyingError);
		[self failWithError:[NSError errorWithDomain:NetworkRequestErrorDomain code:ASIUnhandledExceptionError userInfo:[NSDictionary dictionaryWithObjectsAndKeys:[exception name],NSLocalizedDescriptionKey,[exception reason],NSLocalizedFailureReasonErrorKey,underlyingError,NSUnderlyingErrorKey,nil]]];

	} @finally {
		[[self cancelledLock] unlock];
	}
}

- (void)buildRequestHeaders
{
	if ([self haveBuiltRequestHeaders]) {
		return;
	}
	[self setHaveBuiltRequestHeaders:YES];
	
	if ([self mainRequest]) {
		for (NSString *header in [[self mainRequest] requestHeaders]) {
			[self addRequestHeader:header value:[[[self mainRequest] requestHeaders] valueForKey:header]];
		}
		return;
	}
	
	// Accept a compressed response
	if ([self allowCompressedResponse]) {
		[self addRequestHeader:@"Accept-Encoding" value:@"gzip"];
	}
	
	// Should this request resume an existing download?
	[self updatePartialDownloadSize];
	if ([self partialDownloadSize]) {
		[self addRequestHeader:@"Range" value:[NSString stringWithFormat:@"bytes=%llu-",[self partialDownloadSize]]];
	}
}

- (void)updatePartialDownloadSize
{
	NSFileManager *fileManager = [[[NSFileManager alloc] init] autorelease];

	if ([self allowResumeForFileDownloads] && [self downloadDestinationPath] && [self temporaryFileDownloadPath] && [fileManager fileExistsAtPath:[self temporaryFileDownloadPath]]) {
		NSError *err = nil;
		[self setPartialDownloadSize:[[fileManager attributesOfItemAtPath:[self temporaryFileDownloadPath] error:&err] fileSize]];
		if (err) {
			[self failWithError:[NSError errorWithDomain:NetworkRequestErrorDomain code:ASIFileManagementError userInfo:[NSDictionary dictionaryWithObjectsAndKeys:[NSString stringWithFormat:@"Failed to get attributes for file at path '%@'",[self temporaryFileDownloadPath]],NSLocalizedDescriptionKey,error,NSUnderlyingErrorKey,nil]]];
			return;
		}
	}
}

- (void)startRequest
{
	if ([self isCancelled]) {
		return;
	}
	
	[self performSelectorOnMainThread:@selector(requestStarted) withObject:nil waitUntilDone:[NSThread isMainThread]];
	
	[self setDownloadComplete:NO];
	[self setComplete:NO];
	[self setTotalBytesRead:0];
	[self setLastBytesRead:0];
	
	// If we're retrying a request, let's remove any progress we made
	if ([self lastBytesSent] > 0) {
		[self removeUploadProgressSoFar];
	}
	
	[self setLastBytesSent:0];
	[self setContentLength:0];
	[self setResponseHeaders:nil];
	if (![self downloadDestinationPath]) {
		[self setRawResponseData:[[[NSMutableData alloc] init] autorelease]];
    }
	
	
    //
	// Create the stream for the request
	//

	NSFileManager *fileManager = [[[NSFileManager alloc] init] autorelease];

	[self setReadStreamIsScheduled:NO];
	
	// Do we need to stream the request body from disk
	if ([self shouldStreamPostDataFromDisk] && [self postBodyFilePath] && [fileManager fileExistsAtPath:[self postBodyFilePath]]) {
		
		// Are we gzipping the request body?
		if ([self compressedPostBodyFilePath] && [fileManager fileExistsAtPath:[self compressedPostBodyFilePath]]) {
			[self setPostBodyReadStream:[ASIInputStream inputStreamWithFileAtPath:[self compressedPostBodyFilePath] request:self]];
		} else {
			[self setPostBodyReadStream:[ASIInputStream inputStreamWithFileAtPath:[self postBodyFilePath] request:self]];
		}
		[self setReadStream:[NSMakeCollectable(CFReadStreamCreateForStreamedHTTPRequest(kCFAllocatorDefault, request,(CFReadStreamRef)[self postBodyReadStream])) autorelease]];    
    } else {
		
		// If we have a request body, we'll stream it from memory using our custom stream, so that we can measure bandwidth use and it can be bandwidth-throttled if necessary
		if ([self postBody] && [[self postBody] length] > 0) {
			if ([self postBody]) {
				[self setPostBodyReadStream:[ASIInputStream inputStreamWithData:[self postBody] request:self]];
			}
			[self setReadStream:[NSMakeCollectable(CFReadStreamCreateForStreamedHTTPRequest(kCFAllocatorDefault, request,(CFReadStreamRef)[self postBodyReadStream])) autorelease]];
		
		} else {
			[self setReadStream:[NSMakeCollectable(CFReadStreamCreateForHTTPRequest(kCFAllocatorDefault, request)) autorelease]];
		}
	}

	if (![self readStream]) {
		[self failWithError:[NSError errorWithDomain:NetworkRequestErrorDomain code:ASIInternalErrorWhileBuildingRequestType userInfo:[NSDictionary dictionaryWithObjectsAndKeys:@"Unable to create read stream",NSLocalizedDescriptionKey,nil]]];
        return;
    }


    
    
    //
    // Handle SSL certificate settings
    //

    if([[[[self url] scheme] lowercaseString] isEqualToString:@"https"]) {       
       
        // Tell CFNetwork not to validate SSL certificates
        if (![self validatesSecureCertificate]) {
            // see: http://iphonedevelopment.blogspot.com/2010/05/nsstream-tcp-and-ssl.html
            
            NSDictionary *sslProperties = [[NSDictionary alloc] initWithObjectsAndKeys:
                                      [NSNumber numberWithBool:NO],  kCFStreamSSLValidatesCertificateChain,
                                      kCFNull,kCFStreamSSLPeerName,
                                      nil];
            
            CFReadStreamSetProperty((CFReadStreamRef)[self readStream], 
                                    kCFStreamPropertySSLSettings, 
                                    (CFTypeRef)sslProperties);
            [sslProperties release];
        } 
        
        // Tell CFNetwork to use a client certificate
        if (clientCertificateIdentity) {
            NSMutableDictionary *sslProperties = [NSMutableDictionary dictionaryWithCapacity:1];
            
			NSMutableArray *certificates = [NSMutableArray arrayWithCapacity:[clientCertificates count]+1];

			// The first object in the array is our SecIdentityRef
			[certificates addObject:(id)clientCertificateIdentity];

			// If we've added any additional certificates, add them too
			for (id cert in clientCertificates) {
				[certificates addObject:cert];
			}
            
            [sslProperties setObject:certificates forKey:(NSString *)kCFStreamSSLCertificates];
            
            CFReadStreamSetProperty((CFReadStreamRef)[self readStream], kCFStreamPropertySSLSettings, sslProperties);
        }
        
    }

	//
	// Handle persistent connections
	//
	
	[ASIHTTPRequest expirePersistentConnections];

	[connectionsLock lock];
	
	
	if (![[self url] host] || ![[self url] scheme]) {
		[self setConnectionInfo:nil];
		[self setShouldAttemptPersistentConnection:NO];
	}
	
	// Will store the old stream that was using this connection (if there was one) so we can clean it up once we've opened our own stream
	NSInputStream *oldStream = nil;
	
	// Use a persistent connection if possible
	if ([self shouldAttemptPersistentConnection]) {
		

		// If we are redirecting, we will re-use the current connection only if we are connecting to the same server
		if ([self connectionInfo]) {
			
			if (![[[self connectionInfo] objectForKey:@"host"] isEqualToString:[[self url] host]] || ![[[self connectionInfo] objectForKey:@"scheme"] isEqualToString:[[self url] scheme]] || [(NSNumber *)[[self connectionInfo] objectForKey:@"port"] intValue] != [[[self url] port] intValue]) {
				[self setConnectionInfo:nil];

			// Check if we should have expired this connection
			} else if ([[[self connectionInfo] objectForKey:@"expires"] timeIntervalSinceNow] < 0) {
				#if DEBUG_PERSISTENT_CONNECTIONS
				ASI_DEBUG_LOG(@"[CONNECTION] Not re-using connection #%i because it has expired",[[[self connectionInfo] objectForKey:@"id"] intValue]);
				#endif
				[persistentConnectionsPool removeObject:[self connectionInfo]];
				[self setConnectionInfo:nil];

			} else if ([[self connectionInfo] objectForKey:@"request"] != nil) {
                //Some other request reused this connection already - we'll have to create a new one
				#if DEBUG_PERSISTENT_CONNECTIONS
                ASI_DEBUG_LOG(@"%@ - Not re-using connection #%i for request #%i because it is already used by request #%i",self,[[[self connectionInfo] objectForKey:@"id"] intValue],[[self requestID] intValue],[[[self connectionInfo] objectForKey:@"request"] intValue]);
				#endif
                [self setConnectionInfo:nil];
            }
		}
		
		
		
		if (![self connectionInfo] && [[self url] host] && [[self url] scheme]) { // We must have a proper url with a host and scheme, or this will explode
			
			// Look for a connection to the same server in the pool
			for (NSMutableDictionary *existingConnection in persistentConnectionsPool) {
				if (![existingConnection objectForKey:@"request"] && [[existingConnection objectForKey:@"host"] isEqualToString:[[self url] host]] && [[existingConnection objectForKey:@"scheme"] isEqualToString:[[self url] scheme]] && [(NSNumber *)[existingConnection objectForKey:@"port"] intValue] == [[[self url] port] intValue]) {
					[self setConnectionInfo:existingConnection];
				}
			}
		}
		
		if ([[self connectionInfo] objectForKey:@"stream"]) {
			oldStream = [[[self connectionInfo] objectForKey:@"stream"] retain];

		}
		
		// No free connection was found in the pool matching the server/scheme/port we're connecting to, we'll need to create a new one
		if (![self connectionInfo]) {
			[self setConnectionInfo:[NSMutableDictionary dictionary]];
			nextConnectionNumberToCreate++;
			[[self connectionInfo] setObject:[NSNumber numberWithInt:(int)nextConnectionNumberToCreate] forKey:@"id"];
			[[self connectionInfo] setObject:[[self url] host] forKey:@"host"];
			[[self connectionInfo] setObject:[NSNumber numberWithInt:[[[self url] port] intValue]] forKey:@"port"];
			[[self connectionInfo] setObject:[[self url] scheme] forKey:@"scheme"];
			[persistentConnectionsPool addObject:[self connectionInfo]];
		}
		
		// If we are retrying this request, it will already have a requestID
		if (![self requestID]) {
			nextRequestID++;
			[self setRequestID:[NSNumber numberWithUnsignedInt:nextRequestID]];
		}
		[[self connectionInfo] setObject:[self requestID] forKey:@"request"];		
		[[self connectionInfo] setObject:[self readStream] forKey:@"stream"];
		CFReadStreamSetProperty((CFReadStreamRef)[self readStream],  kCFStreamPropertyHTTPAttemptPersistentConnection, kCFBooleanTrue);
		
		#if DEBUG_PERSISTENT_CONNECTIONS
		ASI_DEBUG_LOG(@"[CONNECTION] Request #%@ will use connection #%i",[self requestID],[[[self connectionInfo] objectForKey:@"id"] intValue]);
		#endif
		
		
		// Tag the stream with an id that tells it which connection to use behind the scenes
		// See http://lists.apple.com/archives/macnetworkprog/2008/Dec/msg00001.html for details on this approach
		
		CFReadStreamSetProperty((CFReadStreamRef)[self readStream], CFSTR("ASIStreamID"), [[self connectionInfo] objectForKey:@"id"]);
	
	} else {
		#if DEBUG_PERSISTENT_CONNECTIONS
		ASI_DEBUG_LOG(@"[CONNECTION] Request %@ will not use a persistent connection",self);
		#endif
	}
	
	[connectionsLock unlock];

	// Schedule the stream
	if (![self readStreamIsScheduled] && (!downloadThrottleWakeUpTime || [downloadThrottleWakeUpTime timeIntervalSinceDate:[NSDate date]] < 0)) {
		[self scheduleReadStream];
	}
	
	BOOL streamSuccessfullyOpened = NO;


   // Start the HTTP connection
	CFStreamClientContext ctxt = {0, self, NULL, NULL, NULL};
    if (CFReadStreamSetClient((CFReadStreamRef)[self readStream], kNetworkEvents, ReadStreamClientCallBack, &ctxt)) {
		if (CFReadStreamOpen((CFReadStreamRef)[self readStream])) {
			streamSuccessfullyOpened = YES;
		}
	}
	
	// Here, we'll close the stream that was previously using this connection, if there was one
	// We've kept it open until now (when we've just opened a new stream) so that the new stream can make use of the old connection
	// http://lists.apple.com/archives/Macnetworkprog/2006/Mar/msg00119.html
	if (oldStream) {
		[oldStream close];
		[oldStream release];
		oldStream = nil;
	}

	if (!streamSuccessfullyOpened) {
		[self setConnectionCanBeReused:NO];
		[self destroyReadStream];
		[self failWithError:[NSError errorWithDomain:NetworkRequestErrorDomain code:ASIInternalErrorWhileBuildingRequestType userInfo:[NSDictionary dictionaryWithObjectsAndKeys:@"Unable to start HTTP connection",NSLocalizedDescriptionKey,nil]]];
		return;	
	}
	
	if (![self mainRequest]) {
		if ([self shouldResetUploadProgress]) {
            [self incrementUploadSizeBy:(long long)[self postLength]];
			[ASIHTTPRequest updateProgressIndicator:&uploadProgressDelegate withProgress:0 ofTotal:1];
		}
		if ([self shouldResetDownloadProgress] && ![self partialDownloadSize]) {
			[ASIHTTPRequest updateProgressIndicator:&downloadProgressDelegate withProgress:0 ofTotal:1];
		}
	}	
	
	
	// Record when the request started, so we can timeout if nothing happens
	[self setLastActivityTime:[NSDate date]];
	[self setStatusTimer:[NSTimer timerWithTimeInterval:0.25 target:self selector:@selector(updateStatus:) userInfo:nil repeats:YES]];
	[[NSRunLoop currentRunLoop] addTimer:[self statusTimer] forMode:[self runLoopMode]];
}

- (void)setStatusTimer:(NSTimer *)timer
{
	CFRetain(self);
	// We must invalidate the old timer here, not before we've created and scheduled a new timer
	// This is because the timer may be the only thing retaining an asynchronous request
	if (statusTimer && timer != statusTimer) {
		[statusTimer invalidate];
		[statusTimer release];
	}
	statusTimer = [timer retain];
	CFRelease(self);
}

// This gets fired every 1/4 of a second to update the progress and work out if we need to timeout
- (void)updateStatus:(__unused NSTimer*)timer
{
	[self checkRequestStatus];
	if (![self inProgress]) {
		[self setStatusTimer:nil];
	}
}

- (BOOL)shouldTimeOut
{
	NSTimeInterval secondsSinceLastActivity = [[NSDate date] timeIntervalSinceDate:lastActivityTime];
	// See if we need to timeout
	if ([self readStream] && [self readStreamIsScheduled] && [self lastActivityTime] && [self timeOutSeconds] > 0 && secondsSinceLastActivity > [self timeOutSeconds]) {
		
		// We have no body, or we've sent more than the upload buffer size,so we can safely time out here
		if ([self postLength] == 0 || ([self uploadBufferSize] > 0 && [self totalBytesSent] > [self uploadBufferSize])) {
			return YES;
			
		// ***Black magic warning***
		// We have a body, but we've taken longer than timeOutSeconds to upload the first small chunk of data
		// Since there's no reliable way to track upload progress for the first 32KB (iPhone) or 128KB (Mac) with CFNetwork, we'll be slightly more forgiving on the timeout, as there's a strong chance our connection is just very slow.
		} else if (secondsSinceLastActivity > [self timeOutSeconds]*1.5) {
			return YES;
		}
	}
	return NO;
}

- (void)checkRequestStatus
{
	// We won't let the request cancel while we're updating progress / checking for a timeout
	[[self cancelledLock] lock];
	// See if our NSOperationQueue told us to cancel
	if ([self isCancelled] || [self complete]) {
		[[self cancelledLock] unlock];
		return;
	}
	
	[self performUploadThrottling];
    [self performDownloadThrottling];

	if ([self shouldTimeOut]) {			
		// Do we need to auto-retry this request?
		if ([self numberOfTimesToRetryOnTimeout] > [self retryCount]) {

			// If we are resuming a download, we may need to update the Range header to take account of data we've just downloaded
			[self updatePartialDownloadSize];
			if ([self partialDownloadSize]) {
				CFHTTPMessageSetHeaderFieldValue(request, (CFStringRef)@"Range", (CFStringRef)[NSString stringWithFormat:@"bytes=%llu-",[self partialDownloadSize]]);
			}
			[self setRetryCount:[self retryCount]+1];
			[self unscheduleReadStream];
			[[self cancelledLock] unlock];
			[self startRequest];
			return;
		}
		[self failWithError:ASIRequestTimedOutError];
		[self cancelLoad];
		[self setComplete:YES];
		[[self cancelledLock] unlock];
		return;
	}

	// readStream will be null if we aren't currently running (perhaps we're waiting for a delegate to supply credentials)
	if ([self readStream]) {
		
		// If we have a post body
		if ([self postLength]) {
		
			[self setLastBytesSent:totalBytesSent];	
			
			// Find out how much data we've uploaded so far
			[self setTotalBytesSent:[[NSMakeCollectable(CFReadStreamCopyProperty((CFReadStreamRef)[self readStream], kCFStreamPropertyHTTPRequestBytesWrittenCount)) autorelease] unsignedLongLongValue]];
			if (totalBytesSent > lastBytesSent) {
				
				// We've uploaded more data,  reset the timeout
				[self setLastActivityTime:[NSDate date]];
				[ASIHTTPRequest incrementUploadBandwidthUsedInLastSecond:(unsigned long)(totalBytesSent-lastBytesSent)];
						
				#if DEBUG_REQUEST_STATUS
				if ([self totalBytesSent] == [self postLength]) {
					ASI_DEBUG_LOG(@"[STATUS] Request %@ finished uploading data",self);
				}
				#endif
			}
		}
			
		[self updateProgressIndicators];

	}
	
	[[self cancelledLock] unlock];
}


// Cancel loading and clean up. DO NOT USE THIS TO CANCEL REQUESTS - use [request cancel] instead
- (void)cancelLoad
{
    [self destroyReadStream];
	
	[[self postBodyReadStream] close];
	[self setPostBodyReadStream:nil];
	
    if ([self rawResponseData]) {
		if (![self complete]) {
			[self setRawResponseData:nil];
		}
	// If we were downloading to a file
	} else if ([self temporaryFileDownloadPath]) {
		[[self fileDownloadOutputStream] close];
		[self setFileDownloadOutputStream:nil];
		
		[[self inflatedFileDownloadOutputStream] close];
		[self setInflatedFileDownloadOutputStream:nil];
		
		// If we haven't said we might want to resume, let's remove the temporary file too
		if (![self complete]) {
			if (![self allowResumeForFileDownloads]) {
				[self removeTemporaryDownloadFile];
			}
			[self removeTemporaryUncompressedDownloadFile];
		}
	}
	
	// Clean up any temporary file used to store request body for streaming
	if ([self didCreateTemporaryPostDataFile]) {
		[self removeTemporaryUploadFile];
		[self removeTemporaryCompressedUploadFile];
		[self setDidCreateTemporaryPostDataFile:NO];
	}
}

#pragma mark upload/download progress


- (void)updateProgressIndicators
{
	//Only update progress if this isn't a HEAD request used to preset the content-length
	if (![self mainRequest]) {
        [self updateUploadProgress];
        [self updateDownloadProgress];
	}
}

- (id)uploadProgressDelegate
{
	[[self cancelledLock] lock];
	id d = [[uploadProgressDelegate retain] autorelease];
	[[self cancelledLock] unlock];
	return d;
}

- (void)setUploadProgressDelegate:(id)newDelegate
{
	[[self cancelledLock] lock];
	uploadProgressDelegate = newDelegate;

	// If the uploadProgressDelegate is an NSProgressIndicator, we set its MaxValue to 1.0 so we can update it as if it were a UIProgressView
	double max = 1.0;
	[ASIHTTPRequest performSelector:@selector(setMaxValue:) onTarget:&uploadProgressDelegate withObject:nil amount:&max callerToRetain:nil];
	[[self cancelledLock] unlock];
}

- (id)downloadProgressDelegate
{
	[[self cancelledLock] lock];
	id d = [[downloadProgressDelegate retain] autorelease];
	[[self cancelledLock] unlock];
	return d;
}

- (void)setDownloadProgressDelegate:(id)newDelegate
{
	[[self cancelledLock] lock];
	downloadProgressDelegate = newDelegate;

	// If the downloadProgressDelegate is an NSProgressIndicator, we set its MaxValue to 1.0 so we can update it as if it were a UIProgressView
	double max = 1.0;
	[ASIHTTPRequest performSelector:@selector(setMaxValue:) onTarget:&downloadProgressDelegate withObject:nil amount:&max callerToRetain:nil];	
	[[self cancelledLock] unlock];
}


- (void)updateDownloadProgress
{
	// We won't update download progress until we've examined the headers, since we might need to authenticate
	if (![self responseHeaders] || !([self contentLength] || [self complete])) {
		return;
	}
		
	unsigned long long bytesReadSoFar = [self totalBytesRead]+[self partialDownloadSize];
	unsigned long long value = 0;
	
	if ([self contentLength]) {
		value = bytesReadSoFar-[self lastBytesRead];
		if (value == 0) {
			return;
		}
	} else {
		value = 1;
		[self setUpdatedProgress:YES];
	}
	if (!value) {
		return;
	}

	[ASIHTTPRequest performSelector:@selector(request:didReceiveBytes:) onTarget:&queue withObject:self amount:&value callerToRetain:self];
	[ASIHTTPRequest performSelector:@selector(request:didReceiveBytes:) onTarget:&downloadProgressDelegate withObject:self amount:&value callerToRetain:self];

	[ASIHTTPRequest updateProgressIndicator:&downloadProgressDelegate withProgress:[self totalBytesRead]+[self partialDownloadSize] ofTotal:[self contentLength]+[self partialDownloadSize]];

    if (bytesReceivedBlock) {
		unsigned long long totalSize = [self contentLength] + [self partialDownloadSize];
		[self performBlockOnMainThread:^{ if (bytesReceivedBlock) { bytesReceivedBlock(value, totalSize); }}];
    }
	[self setLastBytesRead:bytesReadSoFar];
}

- (void)updateUploadProgress
{
	if ([self isCancelled] || [self totalBytesSent] == 0) {
		return;
	}
	
	// If this is the first time we've written to the buffer, totalBytesSent will be the size of the buffer (currently seems to be 128KB on both Leopard and iPhone 2.2.1, 32KB on iPhone 3.0)
	// If request body is less than the buffer size, totalBytesSent will be the total size of the request body
	// We will remove this from any progress display, as kCFStreamPropertyHTTPRequestBytesWrittenCount does not tell us how much data has actually be written
	if ([self uploadBufferSize] == 0 && [self totalBytesSent] != [self postLength]) {
//        [self setUploadBufferSize:[self totalBytesSent]];
        [self setUploadBufferSize:MAX([self totalBytesSent], 128 * 1024)];
        //NSLog(@"uploadbuf %@", @(self.uploadBufferSize));
		[self incrementUploadSizeBy:-(long long)[self uploadBufferSize]];
	}

	unsigned long long value = 0;
	
    if ([self totalBytesSent] == [self postLength] || [self lastBytesSent] > 0) {
        value = [self totalBytesSent]-[self lastBytesSent];
    } else {
        return;
    }

	if (!value) {
		return;
	}
	
	[ASIHTTPRequest performSelector:@selector(request:didSendBytes:) onTarget:&queue withObject:self amount:&value callerToRetain:self];
	[ASIHTTPRequest performSelector:@selector(request:didSendBytes:) onTarget:&uploadProgressDelegate withObject:self amount:&value callerToRetain:self];
	[ASIHTTPRequest updateProgressIndicator:&uploadProgressDelegate withProgress:[self totalBytesSent]-[self uploadBufferSize] ofTotal:[self postLength]-[self uploadBufferSize]];

    if(bytesSentBlock){
		unsigned long long totalSize = [self postLength];
		[self performBlockOnMainThread:^{ if (bytesSentBlock) { bytesSentBlock(value, totalSize); }}];
	}
}


- (void)incrementDownloadSizeBy:(long long)length
{
	[ASIHTTPRequest performSelector:@selector(request:incrementDownloadSizeBy:) onTarget:&queue withObject:self amount:&length callerToRetain:self];
	[ASIHTTPRequest performSelector:@selector(request:incrementDownloadSizeBy:) onTarget:&downloadProgressDelegate withObject:self amount:&length callerToRetain:self];

    if(downloadSizeIncrementedBlock){
		[self performBlockOnMainThread:^{ if (downloadSizeIncrementedBlock) { downloadSizeIncrementedBlock(length); }}];
    }
}

- (void)incrementUploadSizeBy:(long long)length
{
	[ASIHTTPRequest performSelector:@selector(request:incrementUploadSizeBy:) onTarget:&queue withObject:self amount:&length callerToRetain:self];
	[ASIHTTPRequest performSelector:@selector(request:incrementUploadSizeBy:) onTarget:&uploadProgressDelegate withObject:self amount:&length callerToRetain:self];

    if(uploadSizeIncrementedBlock) {
		[self performBlockOnMainThread:^{ if (uploadSizeIncrementedBlock) { uploadSizeIncrementedBlock(length); }}];
    }
}


-(void)removeUploadProgressSoFar
{
	long long progressToRemove = -(long long)[self totalBytesSent];
	[ASIHTTPRequest performSelector:@selector(request:didSendBytes:) onTarget:&queue withObject:self amount:&progressToRemove callerToRetain:self];
	[ASIHTTPRequest performSelector:@selector(request:didSendBytes:) onTarget:&uploadProgressDelegate withObject:self amount:&progressToRemove callerToRetain:self];
	[ASIHTTPRequest updateProgressIndicator:&uploadProgressDelegate withProgress:0 ofTotal:[self postLength]];

    if(bytesSentBlock){
		unsigned long long totalSize = [self postLength];
		[self performBlockOnMainThread:^{  if (bytesSentBlock) { bytesSentBlock((unsigned long long)progressToRemove, totalSize); }}];
	}
}

- (void)performBlockOnMainThread:(ASIBasicBlock)block
{
	[self performSelectorOnMainThread:@selector(callBlock:) withObject:[[block copy] autorelease] waitUntilDone:[NSThread isMainThread]];
}

- (void)callBlock:(ASIBasicBlock)block
{
	block();
}

+ (void)performSelector:(SEL)selector onTarget:(id *)target withObject:(id)object amount:(void *)amount callerToRetain:(id)callerToRetain
{
	if ([*target respondsToSelector:selector]) {
		NSMethodSignature *signature = nil;
		signature = [*target methodSignatureForSelector:selector];
		NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];

		[invocation setSelector:selector];
		
		int argumentNumber = 2;
		
		// If we got an object parameter, we pass a pointer to the object pointer
		if (object) {
			[invocation setArgument:&object atIndex:argumentNumber];
			argumentNumber++;
		}
		
		// For the amount we'll just pass the pointer directly so NSInvocation will call the method using the number itself rather than a pointer to it
		if (amount) {
			[invocation setArgument:amount atIndex:argumentNumber];
		}

        SEL callback = @selector(performInvocation:onTarget:releasingObject:);
        NSMethodSignature *cbSignature = [ASIHTTPRequest methodSignatureForSelector:callback];
        NSInvocation *cbInvocation = [NSInvocation invocationWithMethodSignature:cbSignature];
        [cbInvocation setSelector:callback];
        [cbInvocation setTarget:self];
        [cbInvocation setArgument:&invocation atIndex:2];
        [cbInvocation setArgument:&target atIndex:3];
		if (callerToRetain) {
			[cbInvocation setArgument:&callerToRetain atIndex:4];
		}

		CFRetain(invocation);

		// Used to pass in a request that we must retain until after the call
		// We're using CFRetain rather than [callerToRetain retain] so things to avoid earthquakes when using garbage collection
		if (callerToRetain) {
			CFRetain(callerToRetain);
		}
        [cbInvocation performSelectorOnMainThread:@selector(invoke) withObject:nil waitUntilDone:[NSThread isMainThread]];
    }
}

+ (void)performInvocation:(NSInvocation *)invocation onTarget:(id *)target releasingObject:(id)objectToRelease
{
    if (*target && [*target respondsToSelector:[invocation selector]]) {
        [invocation invokeWithTarget:*target];
    }
	CFRelease(invocation);
	if (objectToRelease) {
		CFRelease(objectToRelease);
	}
}
	
	
+ (void)updateProgressIndicator:(id *)indicator withProgress:(unsigned long long)progress ofTotal:(unsigned long long)total
{
    // Cocoa: NSProgressIndicator
    double progressAmount = progressAmount = (progress*1.0)/(total*1.0);
    SEL selector = @selector(setDoubleValue:);

	if (![*indicator respondsToSelector:selector]) {
		return;
	}
	
	[progressLock lock];
	[ASIHTTPRequest performSelector:selector onTarget:indicator withObject:nil amount:&progressAmount callerToRetain:nil];
	[progressLock unlock];
}


#pragma mark talking to delegates / calling blocks

/* ALWAYS CALLED ON MAIN THREAD! */
- (void)requestStarted
{
	if ([self error] || [self mainRequest]) {
		return;
	}
	if (delegate && [delegate respondsToSelector:didStartSelector]) {
		[delegate performSelector:didStartSelector withObject:self];
	}
	if(startedBlock){
		startedBlock();
	}
	if (queue && [queue respondsToSelector:@selector(requestStarted:)]) {
		[queue performSelector:@selector(requestStarted:) withObject:self];
	}
}

/* ALWAYS CALLED ON MAIN THREAD! */
- (void)requestReceivedResponseHeaders:(NSMutableDictionary *)newResponseHeaders
{
	if ([self error] || [self mainRequest]) {
		return;
	}

	if (delegate && [delegate respondsToSelector:didReceiveResponseHeadersSelector]) {
		[delegate performSelector:didReceiveResponseHeadersSelector withObject:self withObject:newResponseHeaders];
	}

	if(headersReceivedBlock){
		headersReceivedBlock(newResponseHeaders);
    }

	if (queue && [queue respondsToSelector:@selector(request:didReceiveResponseHeaders:)]) {
		[queue performSelector:@selector(request:didReceiveResponseHeaders:) withObject:self withObject:newResponseHeaders];
	}
}

// Subclasses might override this method to process the result in the same thread
// If you do this, don't forget to call [super requestFinished] to let the queue / delegate know we're done
- (void)requestFinished
{
#if DEBUG_REQUEST_STATUS || DEBUG_THROTTLING
	ASI_DEBUG_LOG(@"[STATUS] Request finished: %@",self);
#endif
	if ([self error] || [self mainRequest]) {
		return;
	}
    [self performSelectorOnMainThread:@selector(reportFinished) withObject:nil waitUntilDone:[NSThread isMainThread]];
}

/* ALWAYS CALLED ON MAIN THREAD! */
- (void)reportFinished
{
	if (delegate && [delegate respondsToSelector:didFinishSelector]) {
		[delegate performSelector:didFinishSelector withObject:self];
	}

	if(completionBlock){
		completionBlock();
	}

	if (queue && [queue respondsToSelector:@selector(requestFinished:)]) {
		[queue performSelector:@selector(requestFinished:) withObject:self];
	}
}

/* ALWAYS CALLED ON MAIN THREAD! */
- (void)reportFailure
{
	if (delegate && [delegate respondsToSelector:didFailSelector]) {
		[delegate performSelector:didFailSelector withObject:self];
	}

    if(failureBlock){
        failureBlock();
    }

	if (queue && [queue respondsToSelector:@selector(requestFailed:)]) {
		[queue performSelector:@selector(requestFailed:) withObject:self];
	}
}

/* ALWAYS CALLED ON MAIN THREAD! */
- (void)passOnReceivedData:(NSData *)data
{
	if (delegate && [delegate respondsToSelector:didReceiveDataSelector]) {
		[delegate performSelector:didReceiveDataSelector withObject:self withObject:data];
	}

	if (dataReceivedBlock) {
		dataReceivedBlock(data);
	}
}

// Subclasses might override this method to perform error handling in the same thread
// If you do this, don't forget to call [super failWithError:] to let the queue / delegate know we're done
- (void)failWithError:(NSError *)theError
{
#if DEBUG_REQUEST_STATUS || DEBUG_THROTTLING
	ASI_DEBUG_LOG(@"[STATUS] Request %@: %@",self,(theError == ASIRequestCancelledError ? @"Cancelled" : @"Failed"));
#endif
	[self setComplete:YES];
	
	// Invalidate the current connection so subsequent requests don't attempt to reuse it
	if (theError && [theError code] != ASIAuthenticationErrorType && [theError code] != ASITooMuchRedirectionErrorType) {
		[connectionsLock lock];
		#if DEBUG_PERSISTENT_CONNECTIONS
		ASI_DEBUG_LOG(@"[CONNECTION] Request #%@ failed and will invalidate connection #%@",[self requestID],[[self connectionInfo] objectForKey:@"id"]);
		#endif
		[[self connectionInfo] removeObjectForKey:@"request"];
		[persistentConnectionsPool removeObject:[self connectionInfo]];
		[connectionsLock unlock];
		[self destroyReadStream];
	}
	if ([self connectionCanBeReused]) {
		[[self connectionInfo] setObject:[NSDate dateWithTimeIntervalSinceNow:[self persistentConnectionTimeoutSeconds]] forKey:@"expires"];
	}
	
    if ([self isCancelled] || [self error]) {
		return;
	}
	
	[self setError:theError];
	
	ASIHTTPRequest *failedRequest = self;
	
	// If this is a HEAD request created by an ASINetworkQueue or compatible queue delegate, make the main request fail
	if ([self mainRequest]) {
		failedRequest = [self mainRequest];
		[failedRequest setError:theError];
	}

    [failedRequest performSelectorOnMainThread:@selector(reportFailure) withObject:nil waitUntilDone:[NSThread isMainThread]];
	
    if (!inProgress)
    {
        // if we're not in progress, we can't notify the queue we've finished (doing so can cause a crash later on)
        // "markAsFinished" will be at the start of main() when we are started
        return;
    }
	[self markAsFinished];
}

#pragma mark parsing HTTP response headers

- (void)readResponseHeaders
{
	CFHTTPMessageRef message = (CFHTTPMessageRef)CFReadStreamCopyProperty((CFReadStreamRef)[self readStream], kCFStreamPropertyHTTPResponseHeader);
	if (!message) {
		return;
	}
	
	// Make sure we've received all the headers
	if (!CFHTTPMessageIsHeaderComplete(message)) {
		CFRelease(message);
		return;
	}

	#if DEBUG_REQUEST_STATUS
	if ([self totalBytesSent] == [self postLength]) {
		ASI_DEBUG_LOG(@"[STATUS] Request %@ received response headers",self);
	}
	#endif		

	[self setResponseHeaders:[NSMakeCollectable(CFHTTPMessageCopyAllHeaderFields(message)) autorelease]];
	[self setResponseStatusCode:(int)CFHTTPMessageGetResponseStatusCode(message)];
	[self setResponseStatusMessage:[NSMakeCollectable(CFHTTPMessageCopyResponseStatusLine(message)) autorelease]];

    // See if we got a Content-length header
    NSString *cLength = [responseHeaders valueForKey:@"Content-Length"];
    ASIHTTPRequest *theRequest = self;
    if ([self mainRequest]) {
        theRequest = [self mainRequest];
    }

    if (cLength) {
        unsigned long long length = strtoull([cLength UTF8String], NULL, 0);

        // Workaround for Apache HEAD requests for dynamically generated content returning the wrong Content-Length when using gzip
        if ([self mainRequest] && [self allowCompressedResponse] && length == 20 && [self shouldResetDownloadProgress]) {
            [[self mainRequest] incrementDownloadSizeBy:1];

        } else {
            [theRequest setContentLength:length];
            if ([self shouldResetDownloadProgress]) {
                [theRequest incrementDownloadSizeBy:(long long)[theRequest contentLength]+(long long)[theRequest partialDownloadSize]];
            }
        }

    } else if ([self shouldResetDownloadProgress]) {
        [theRequest incrementDownloadSizeBy:1];
    }

	// Handle connection persistence
	if ([self shouldAttemptPersistentConnection]) {
		
		NSString *connectionHeader = [[[self responseHeaders] objectForKey:@"Connection"] lowercaseString];

		NSString *httpVersion = [NSMakeCollectable(CFHTTPMessageCopyVersion(message)) autorelease];
		
		// Don't re-use the connection if the server is HTTP 1.0 and didn't send Connection: Keep-Alive
		if (![httpVersion isEqualToString:(NSString *)kCFHTTPVersion1_0] || [connectionHeader isEqualToString:@"keep-alive"]) {

			// See if server explicitly told us to close the connection
			if (![connectionHeader isEqualToString:@"close"]) {
				
				NSString *keepAliveHeader = [[self responseHeaders] objectForKey:@"Keep-Alive"];
				
				// If we got a keep alive header, we'll reuse the connection for as long as the server tells us
				if (keepAliveHeader) { 
					int timeout = 0;
					int max = 0;
					NSScanner *scanner = [NSScanner scannerWithString:keepAliveHeader];
					[scanner scanString:@"timeout=" intoString:NULL];
					[scanner scanInt:&timeout];
					[scanner scanUpToString:@"max=" intoString:NULL];
					[scanner scanString:@"max=" intoString:NULL];
					[scanner scanInt:&max];
					if (max > 5) {
						[self setConnectionCanBeReused:YES];
						[self setPersistentConnectionTimeoutSeconds:timeout];
						#if DEBUG_PERSISTENT_CONNECTIONS
							ASI_DEBUG_LOG(@"[CONNECTION] Got a keep-alive header, will keep this connection open for %f seconds", [self persistentConnectionTimeoutSeconds]);
						#endif					
					}
				
				// Otherwise, we'll assume we can keep this connection open
				} else {
					[self setConnectionCanBeReused:YES];
					#if DEBUG_PERSISTENT_CONNECTIONS
						ASI_DEBUG_LOG(@"[CONNECTION] Got no keep-alive header, will keep this connection open for %f seconds", [self persistentConnectionTimeoutSeconds]);
					#endif
				}
			}
		}
	}

	CFRelease(message);
	[self performSelectorOnMainThread:@selector(requestReceivedResponseHeaders:) withObject:[[[self responseHeaders] copy] autorelease] waitUntilDone:[NSThread isMainThread]];
}

#pragma mark stream status handlers

- (void)handleNetworkEvent:(CFStreamEventType)type
{	
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

	[[self cancelledLock] lock];
	
	if ([self complete] || [self isCancelled]) {
		[[self cancelledLock] unlock];
		[pool drain];
		return;
	}

	CFRetain(self);

    // Dispatch the stream events.
    switch (type) {
        case kCFStreamEventHasBytesAvailable:
            [self handleBytesAvailable];
            break;
            
        case kCFStreamEventEndEncountered:
            [self handleStreamComplete];
            break;
            
        case kCFStreamEventErrorOccurred:
            [self handleStreamError];
            break;
            
        default:
            break;
    }
	
	[self performDownloadThrottling];
	
	[[self cancelledLock] unlock];
	
	CFRelease(self);
	[pool drain];
}

- (void)handleBytesAvailable
{
	if (![self responseHeaders]) {
		[self readResponseHeaders];
	}
	
	// If we've cancelled the load part way through (for example, after deciding to use a cached version)
	if ([self complete]) {
		return;
	}
	
	// In certain (presumably very rare) circumstances, handleBytesAvailable seems to be called when there isn't actually any data available
	// We'll check that there is actually data available to prevent blocking on CFReadStreamRead()
	// So far, I've only seen this in the stress tests, so it might never happen in real-world situations.
	if (!CFReadStreamHasBytesAvailable((CFReadStreamRef)[self readStream])) {
		return;
	}

	long long bufferSize = 16384;
	if (contentLength > 262144) {
		bufferSize = 262144;
	} else if (contentLength > 65536) {
		bufferSize = 65536;
	}
	
	// Reduce the buffer size if we're receiving data too quickly when bandwidth throttling is active
	// This just augments the throttling done in measureBandwidthUsage to reduce the amount we go over the limit
	
	if ([[self class] isDownloadBandwidthThrottled]) {
		[downloadBandwidthThrottlingLock lock];
		if (maxDownloadBandwidthPerSecond > 0) {
			long long maxiumumSize  = (long long)maxDownloadBandwidthPerSecond-(long long)downloadBandwidthUsedInLastSecond;
			if (maxiumumSize < 0) {
				// We aren't supposed to read any more data right now, but we'll read a single byte anyway so the CFNetwork's buffer isn't full
				bufferSize = 1;
			} else if (maxiumumSize/4 < bufferSize) {
				// We were going to fetch more data that we should be allowed, so we'll reduce the size of our read
				bufferSize = maxiumumSize/4;
			}
		}
		if (bufferSize < 1) {
			bufferSize = 1;
		}
		[downloadBandwidthThrottlingLock unlock];
	}
	
	
    UInt8 buffer[bufferSize];
    NSInteger bytesRead = [[self readStream] read:buffer maxLength:sizeof(buffer)];

    // Less than zero is an error
    if (bytesRead < 0) {
        [self handleStreamError];
		
	// If zero bytes were read, wait for the EOF to come.
    } else if (bytesRead) {

		// If we are inflating the response on the fly
		NSData *inflatedData = nil;
		if ([self isResponseCompressed] && ![self shouldWaitToInflateCompressedResponses]) {
			if (![self dataDecompressor]) {
				[self setDataDecompressor:[ASIDataDecompressor decompressor]];
			}
			NSError *err = nil;
			inflatedData = [[self dataDecompressor] uncompressBytes:buffer length:(NSUInteger)bytesRead error:&err];
			if (err) {
				[self failWithError:err];
				return;
			}
		}
		
		[self setTotalBytesRead:[self totalBytesRead]+(NSUInteger)bytesRead];
		[self setLastActivityTime:[NSDate date]];

		// For bandwidth measurement / throttling
		[ASIHTTPRequest incrementDownloadBandwidthUsedInLastSecond:(NSUInteger)bytesRead];
		
		BOOL dataWillBeHandledExternally = NO;
		if ([[self delegate] respondsToSelector:[self didReceiveDataSelector]]) {
			dataWillBeHandledExternally = YES;
		}
		if (dataReceivedBlock) {
			dataWillBeHandledExternally = YES;
		}
		// Does the delegate want to handle the data manually?
		if (dataWillBeHandledExternally) {

			NSData *data = nil;
			if ([self isResponseCompressed] && ![self shouldWaitToInflateCompressedResponses]) {
				data = inflatedData;
			} else {
				data = [NSData dataWithBytes:buffer length:(NSUInteger)bytesRead];
			}
			[self performSelectorOnMainThread:@selector(passOnReceivedData:) withObject:data waitUntilDone:[NSThread isMainThread]];
			
		// Are we downloading to a file?
		} else if ([self downloadDestinationPath]) {
			BOOL append = NO;
			if (![self fileDownloadOutputStream]) {
				if (![self temporaryFileDownloadPath]) {
					[self setTemporaryFileDownloadPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]]];
				} else if ([self allowResumeForFileDownloads] && [[self requestHeaders] objectForKey:@"Range"]) {
					if ([[self responseHeaders] objectForKey:@"Content-Range"]) {
						append = YES;
					} else {
						[self incrementDownloadSizeBy:-(long long)[self partialDownloadSize]];
						[self setPartialDownloadSize:0];
					}
				}

				[self setFileDownloadOutputStream:[[[NSOutputStream alloc] initToFileAtPath:[self temporaryFileDownloadPath] append:append] autorelease]];
				[[self fileDownloadOutputStream] open];

			}
			[[self fileDownloadOutputStream] write:buffer maxLength:(NSUInteger)bytesRead];

			if ([self isResponseCompressed] && ![self shouldWaitToInflateCompressedResponses]) {
				
				if (![self inflatedFileDownloadOutputStream]) {
					if (![self temporaryUncompressedDataDownloadPath]) {
						[self setTemporaryUncompressedDataDownloadPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]]];
					}
					
					[self setInflatedFileDownloadOutputStream:[[[NSOutputStream alloc] initToFileAtPath:[self temporaryUncompressedDataDownloadPath] append:append] autorelease]];
					[[self inflatedFileDownloadOutputStream] open];
				}

				[[self inflatedFileDownloadOutputStream] write:[inflatedData bytes] maxLength:[inflatedData length]];
			}

			
		//Otherwise, let's add the data to our in-memory store
		} else {
			if ([self isResponseCompressed] && ![self shouldWaitToInflateCompressedResponses]) {
				[rawResponseData appendData:inflatedData];
			} else {
				[rawResponseData appendBytes:buffer length:(NSUInteger)bytesRead];
			}
		}
    }
}

- (void)handleStreamComplete
{
#if DEBUG_REQUEST_STATUS
	ASI_DEBUG_LOG(@"[STATUS] Request %@ finished downloading data (%qu bytes)",self, [self totalBytesRead]);
#endif
	[self setStatusTimer:nil];
	[self setDownloadComplete:YES];
	
	if (![self responseHeaders]) {
		[self readResponseHeaders];
	}

	[progressLock lock];	
	// Find out how much data we've uploaded so far
	[self setLastBytesSent:totalBytesSent];	
	[self setTotalBytesSent:[[NSMakeCollectable(CFReadStreamCopyProperty((CFReadStreamRef)[self readStream], kCFStreamPropertyHTTPRequestBytesWrittenCount)) autorelease] unsignedLongLongValue]];
	[self setComplete:YES];
	if (![self contentLength]) {
		[self setContentLength:[self totalBytesRead]];
	}
	[self updateProgressIndicators];

	
	[[self postBodyReadStream] close];
	[self setPostBodyReadStream:nil];
	
	[self setDataDecompressor:nil];

	NSError *fileError = nil;
	
	// Delete up the request body temporary file, if it exists
	if ([self didCreateTemporaryPostDataFile]) {
		[self removeTemporaryUploadFile];
		[self removeTemporaryCompressedUploadFile];
	}
	
	// Close the output stream as we're done writing to the file
	if ([self temporaryFileDownloadPath]) {
		
		[[self fileDownloadOutputStream] close];
		[self setFileDownloadOutputStream:nil];

		[[self inflatedFileDownloadOutputStream] close];
		[self setInflatedFileDownloadOutputStream:nil];

		if ([self isResponseCompressed]) {
			
			// Decompress the file directly to the destination path
			if ([self shouldWaitToInflateCompressedResponses]) {
				[ASIDataDecompressor uncompressDataFromFile:[self temporaryFileDownloadPath] toFile:[self downloadDestinationPath] error:&fileError];

			// Response should already have been inflated, move the temporary file to the destination path
			} else {
				NSError *moveError = nil;
				[[[[NSFileManager alloc] init] autorelease] moveItemAtPath:[self temporaryUncompressedDataDownloadPath] toPath:[self downloadDestinationPath] error:&moveError];
				if (moveError) {
					fileError = [NSError errorWithDomain:NetworkRequestErrorDomain code:ASIFileManagementError userInfo:[NSDictionary dictionaryWithObjectsAndKeys:[NSString stringWithFormat:@"Failed to move file from '%@' to '%@'",[self temporaryFileDownloadPath],[self downloadDestinationPath]],NSLocalizedDescriptionKey,moveError,NSUnderlyingErrorKey,nil]];
				}
				[self setTemporaryUncompressedDataDownloadPath:nil];

			}
			[self removeTemporaryDownloadFile];

		} else {
	
			//Remove any file at the destination path
			NSError *moveError = nil;
			if (![[self class] removeFileAtPath:[self downloadDestinationPath] error:&moveError]) {
				fileError = moveError;

			}

			//Move the temporary file to the destination path
			if (!fileError) {
				[[[[NSFileManager alloc] init] autorelease] moveItemAtPath:[self temporaryFileDownloadPath] toPath:[self downloadDestinationPath] error:&moveError];
				if (moveError) {
					fileError = [NSError errorWithDomain:NetworkRequestErrorDomain code:ASIFileManagementError userInfo:[NSDictionary dictionaryWithObjectsAndKeys:[NSString stringWithFormat:@"Failed to move file from '%@' to '%@'",[self temporaryFileDownloadPath],[self downloadDestinationPath]],NSLocalizedDescriptionKey,moveError,NSUnderlyingErrorKey,nil]];
				}
				[self setTemporaryFileDownloadPath:nil];
			}
			
		}
	}

	[progressLock unlock];

	
	[connectionsLock lock];
	if (![self connectionCanBeReused]) {
		[self unscheduleReadStream];
	}
	#if DEBUG_PERSISTENT_CONNECTIONS
	if ([self requestID]) {
		ASI_DEBUG_LOG(@"[CONNECTION] Request #%@ finished using connection #%@",[self requestID], [[self connectionInfo] objectForKey:@"id"]);
	}
	#endif
	[[self connectionInfo] removeObjectForKey:@"request"];
	[[self connectionInfo] setObject:[NSDate dateWithTimeIntervalSinceNow:[self persistentConnectionTimeoutSeconds]] forKey:@"expires"];
	[connectionsLock unlock];
	
    [self destroyReadStream];

    if (fileError) {
        [self failWithError:fileError];
    } else {
        [self requestFinished];
    }

    [self markAsFinished];
}

- (void)markAsFinished
{
	// Autoreleased requests may well be dealloced here otherwise
	CFRetain(self);

	// dealloc won't be called when running with GC, so we'll clean these up now
	if (request) {
		CFRelease(request);
		request = nil;
	}
	if (requestAuthentication) {
		CFRelease(requestAuthentication);
		requestAuthentication = nil;
	}

    BOOL wasInProgress = inProgress;
    BOOL wasFinished = finished;

    if (!wasFinished)
        [self willChangeValueForKey:@"isFinished"];
    if (wasInProgress)
        [self willChangeValueForKey:@"isExecuting"];

	[self setInProgress:NO];
    finished = YES;

    if (wasInProgress)
        [self didChangeValueForKey:@"isExecuting"];
    if (!wasFinished)
        [self didChangeValueForKey:@"isFinished"];

	CFRelease(self);
}

- (void)handleStreamError
{
	NSError *underlyingError = [NSMakeCollectable(CFReadStreamCopyError((CFReadStreamRef)[self readStream])) autorelease];
    NSLog(@"handleStreamError %@", underlyingError);

	if (![self error]) { // We may already have handled this error
		
		NSString *reason = @"A connection failure occurred";
		
		// We'll use a custom error message for SSL errors, but you should always check underlying error if you want more details
		// For some reason SecureTransport.h doesn't seem to be available on iphone, so error codes hard-coded
		// Also, iPhone seems to handle errors differently from Mac OS X - a self-signed certificate returns a different error code on each platform, so we'll just provide a general error
		if ([[underlyingError domain] isEqualToString:NSOSStatusErrorDomain]) {
			if ([underlyingError code] <= -9800 && [underlyingError code] >= -9818) {
				reason = [NSString stringWithFormat:@"%@: SSL problem (Possible causes may include a bad/expired/self-signed certificate, clock set to wrong date)",reason];
			}
		}
		[self cancelLoad];
		[self failWithError:[NSError errorWithDomain:NetworkRequestErrorDomain code:ASIConnectionFailureErrorType userInfo:[NSDictionary dictionaryWithObjectsAndKeys:reason,NSLocalizedDescriptionKey,underlyingError,NSUnderlyingErrorKey,nil]]];
	} else {
		[self cancelLoad];
	}
	[self checkRequestStatus];
}

#pragma mark managing the read stream

- (void)destroyReadStream
{
    if ([self readStream]) {
		[self unscheduleReadStream];
		if (![self connectionCanBeReused]) {
			[[self readStream] removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:[self runLoopMode]];
			[[self readStream] close];
		}
		[self setReadStream:nil];
    }	
}

- (void)scheduleReadStream
{
	if ([self readStream] && ![self readStreamIsScheduled]) {

		[connectionsLock lock];
		runningRequestCount++;
		[connectionsLock unlock];

		// Reset the timeout
		[self setLastActivityTime:[NSDate date]];
		CFStreamClientContext ctxt = {0, self, NULL, NULL, NULL};
		CFReadStreamSetClient((CFReadStreamRef)[self readStream], kNetworkEvents, ReadStreamClientCallBack, &ctxt);
		[[self readStream] scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:[self runLoopMode]];
		[self setReadStreamIsScheduled:YES];
	}
}


- (void)unscheduleReadStream
{
	if ([self readStream] && [self readStreamIsScheduled]) {

		[connectionsLock lock];
		runningRequestCount--;
		[connectionsLock unlock];

		CFReadStreamSetClient((CFReadStreamRef)[self readStream], kCFStreamEventNone, NULL, NULL);
		[[self readStream] removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:[self runLoopMode]];
		[self setReadStreamIsScheduled:NO];
	}
}

#pragma mark cleanup

- (BOOL)removeTemporaryDownloadFile
{
	NSError *err = nil;
	if ([self temporaryFileDownloadPath]) {
		if (![[self class] removeFileAtPath:[self temporaryFileDownloadPath] error:&err]) {
			[self failWithError:err];
		}
		[self setTemporaryFileDownloadPath:nil];
	}
	return (!err);
}

- (BOOL)removeTemporaryUncompressedDownloadFile
{
	NSError *err = nil;
	if ([self temporaryUncompressedDataDownloadPath]) {
		if (![[self class] removeFileAtPath:[self temporaryUncompressedDataDownloadPath] error:&err]) {
			[self failWithError:err];
		}
		[self setTemporaryUncompressedDataDownloadPath:nil];
	}
	return (!err);
}

- (BOOL)removeTemporaryUploadFile
{
	NSError *err = nil;
	if ([self postBodyFilePath]) {
		if (![[self class] removeFileAtPath:[self postBodyFilePath] error:&err]) {
			[self failWithError:err];
		}
		[self setPostBodyFilePath:nil];
	}
	return (!err);
}

- (BOOL)removeTemporaryCompressedUploadFile
{
	NSError *err = nil;
	if ([self compressedPostBodyFilePath]) {
		if (![[self class] removeFileAtPath:[self compressedPostBodyFilePath] error:&err]) {
			[self failWithError:err];
		}
		[self setCompressedPostBodyFilePath:nil];
	}
	return (!err);
}

+ (BOOL)removeFileAtPath:(NSString *)path error:(NSError **)err
{
	NSFileManager *fileManager = [[[NSFileManager alloc] init] autorelease];

	if ([fileManager fileExistsAtPath:path]) {
		NSError *removeError = nil;
		[fileManager removeItemAtPath:path error:&removeError];
		if (removeError) {
			if (err) {
				*err = [NSError errorWithDomain:NetworkRequestErrorDomain code:ASIFileManagementError userInfo:[NSDictionary dictionaryWithObjectsAndKeys:[NSString stringWithFormat:@"Failed to delete file at path '%@'",path],NSLocalizedDescriptionKey,removeError,NSUnderlyingErrorKey,nil]];
			}
			return NO;
		}
	}
	return YES;
}

#pragma mark persistent connections

- (NSNumber *)connectionID
{
	return [[self connectionInfo] objectForKey:@"id"];
}

+ (void)expirePersistentConnections
{
	[connectionsLock lock];
	NSUInteger i;
	for (i=0; i<[persistentConnectionsPool count]; i++) {
		NSDictionary *existingConnection = [persistentConnectionsPool objectAtIndex:i];
		if (![existingConnection objectForKey:@"request"] && [[existingConnection objectForKey:@"expires"] timeIntervalSinceNow] <= 0) {
#if DEBUG_PERSISTENT_CONNECTIONS
			ASI_DEBUG_LOG(@"[CONNECTION] Closing connection #%i because it has expired",[[existingConnection objectForKey:@"id"] intValue]);
#endif
			NSInputStream *stream = [existingConnection objectForKey:@"stream"];
			if (stream) {
				[stream close];
			}
			[persistentConnectionsPool removeObject:existingConnection];
			i--;
		}
	}	
	[connectionsLock unlock];
}

#pragma mark default time out

+ (NSTimeInterval)defaultTimeOutSeconds
{
	return defaultTimeOutSeconds;
}

+ (void)setDefaultTimeOutSeconds:(NSTimeInterval)newTimeOutSeconds
{
	defaultTimeOutSeconds = newTimeOutSeconds;
}


#pragma mark client certificate

- (void)setClientCertificateIdentity:(SecIdentityRef)anIdentity {
    if(clientCertificateIdentity) {
        CFRelease(clientCertificateIdentity);
    }
    
    clientCertificateIdentity = anIdentity;
    
	if (clientCertificateIdentity) {
		CFRetain(clientCertificateIdentity);
	}
}

#pragma mark bandwidth measurement / throttling

- (void)performDownloadThrottling
{
	if (![self readStream]) {
		return;
	}
	[ASIHTTPRequest measureDownloadBandwidthUsage];
	if ([ASIHTTPRequest isDownloadBandwidthThrottled]) {
		[downloadBandwidthThrottlingLock lock];
		// Handle throttling
		if (downloadThrottleWakeUpTime) {
			if ([downloadThrottleWakeUpTime timeIntervalSinceDate:[NSDate date]] > 0) {
				if ([self readStreamIsScheduled]) {
					[self unscheduleReadStream];
					#if DEBUG_THROTTLING
					ASI_DEBUG_LOG(@"[DOWNLOAD THROTTLING] Sleeping request %@ until after %@",self,downloadThrottleWakeUpTime);
					#endif
				}
			} else {
				if (![self readStreamIsScheduled]) {
					[self scheduleReadStream];
					#if DEBUG_THROTTLING
					ASI_DEBUG_LOG(@"[DOWNLOAD THROTTLING] Waking up request %@",self);
					#endif
				}
			}
		} 
		[downloadBandwidthThrottlingLock unlock];
		
	// Bandwidth throttling must have been turned off since we last looked, let's re-schedule the stream
	} else if (![self readStreamIsScheduled]) {
		[self scheduleReadStream];			
	}
}

- (void)performUploadThrottling
{
    if (![self readStream]) {
        return;
    }
    [ASIHTTPRequest measureUploadBandwidthUsage];
    if ([ASIHTTPRequest isUploadBandwidthThrottled]) {
        [uploadBandwidthThrottlingLock lock];
        // Handle throttling
        if (uploadThrottleWakeUpTime) {
            if ([uploadThrottleWakeUpTime timeIntervalSinceDate:[NSDate date]] > 0) {
                if ([self readStreamIsScheduled]) {
                    [self unscheduleReadStream];
#if DEBUG_THROTTLING
                    ASI_DEBUG_LOG(@"[UPLOAD THROTTLING] Sleeping request %@ until after %@", self,uploadThrottleWakeUpTime);
#endif
                }
            } else {
                if (![self readStreamIsScheduled]) {
                    [self scheduleReadStream];
#if DEBUG_THROTTLING
                    ASI_DEBUG_LOG(@"[UPLOAD THROTTLING] Waking up request %@", self);
#endif
                }
            }
        }
        [uploadBandwidthThrottlingLock unlock];

        // Bandwidth throttling must have been turned off since we last looked, let's re-schedule the stream
    } else if (![self readStreamIsScheduled]) {
        [self scheduleReadStream];			
    }
}

+ (BOOL)isDownloadBandwidthThrottled
{
	[downloadBandwidthThrottlingLock lock];
	BOOL throttle = (maxDownloadBandwidthPerSecond > 0);
	[downloadBandwidthThrottlingLock unlock];
	return throttle;
}

+ (BOOL)isUploadBandwidthThrottled
{
    [uploadBandwidthThrottlingLock lock];
    BOOL throttle = (maxUploadBandwidthPerSecond > 0);
    [uploadBandwidthThrottlingLock unlock];
    return throttle;
}

+ (unsigned long)maxDownloadBandwidthPerSecond
{
	[downloadBandwidthThrottlingLock lock];
	unsigned long amount = maxDownloadBandwidthPerSecond;
	[downloadBandwidthThrottlingLock unlock];
	return amount;
}

+ (unsigned long)maxUploadBandwidthPerSecond
{
    [uploadBandwidthThrottlingLock lock];
    unsigned long amount = maxUploadBandwidthPerSecond;
    [uploadBandwidthThrottlingLock unlock];
    return amount;
}

+ (void)setMaxDownloadBandwidthPerSecond:(unsigned long)bytes
{
	[downloadBandwidthThrottlingLock lock];
	maxDownloadBandwidthPerSecond = bytes;
	[downloadBandwidthThrottlingLock unlock];
}

+ (void)setMaxUploadBandwidthPerSecond:(unsigned long)bytes
{
    [uploadBandwidthThrottlingLock lock];
    maxUploadBandwidthPerSecond = bytes;
    [uploadBandwidthThrottlingLock unlock];
}

+ (void)incrementDownloadBandwidthUsedInLastSecond:(unsigned long)bytes
{
	[downloadBandwidthThrottlingLock lock];
	downloadBandwidthUsedInLastSecond += bytes;
	[downloadBandwidthThrottlingLock unlock];
}

+ (void)incrementUploadBandwidthUsedInLastSecond:(unsigned long)bytes
{
    [uploadBandwidthThrottlingLock lock];
    uploadBandwidthUsedInLastSecond += bytes;
    [uploadBandwidthThrottlingLock unlock];
}

+ (void)recordDownloadBandwidthUsage
{
	if (downloadBandwidthUsedInLastSecond == 0) {
		[downloadBandwidthUsageTracker removeAllObjects];
	} else {
		NSTimeInterval interval = [downloadBandwidthMeasurementDate timeIntervalSinceNow];
		while ((interval < 0 || [downloadBandwidthUsageTracker count] > 5) && [downloadBandwidthUsageTracker count] > 0) {
			[downloadBandwidthUsageTracker removeObjectAtIndex:0];
			interval++;
		}
	}
	#if DEBUG_THROTTLING
	ASI_DEBUG_LOG(@"[DOWNLOAD THROTTLING] ===Used: %lu bytes of bandwidth in last measurement period===", downloadBandwidthUsedInLastSecond);
	#endif
	[downloadBandwidthUsageTracker addObject:[NSNumber numberWithUnsignedLong:downloadBandwidthUsedInLastSecond]];
	[downloadBandwidthMeasurementDate release];
	downloadBandwidthMeasurementDate = [[NSDate dateWithTimeIntervalSinceNow:1] retain];
	downloadBandwidthUsedInLastSecond = 0;
	
	NSUInteger measurements = [downloadBandwidthUsageTracker count];
	unsigned long totalBytes = 0;
	for (NSNumber *bytes in downloadBandwidthUsageTracker) {
		totalBytes += [bytes unsignedLongValue];
	}
	if (measurements > 0)
		averageDownloadBandwidthUsedPerSecond = totalBytes/measurements;
}

+ (void)recordUploadBandwidthUsage
{
    if (uploadBandwidthUsedInLastSecond == 0) {
        [uploadBandwidthUsageTracker removeAllObjects];
    } else {
        NSTimeInterval interval = [uploadBandwidthMeasurementDate timeIntervalSinceNow];
        while ((interval < 0 || [uploadBandwidthUsageTracker count] > 5) && [uploadBandwidthUsageTracker count] > 0) {
            [uploadBandwidthUsageTracker removeObjectAtIndex:0];
            interval++;
        }
    }
#if DEBUG_THROTTLING
    ASI_DEBUG_LOG(@"[UPLOAD THROTTLING] ===Used: %lu bytes of bandwidth in last measurement period=== av:%@",uploadBandwidthUsedInLastSecond, @(averageUploadBandwidthUsedPerSecond / 1024.0));
#endif
    [uploadBandwidthUsageTracker addObject:[NSNumber numberWithUnsignedLong:uploadBandwidthUsedInLastSecond]];
    [uploadBandwidthMeasurementDate release];
    uploadBandwidthMeasurementDate = [[NSDate dateWithTimeIntervalSinceNow:1] retain];
    uploadBandwidthUsedInLastSecond = 0;

    NSUInteger measurements = [uploadBandwidthUsageTracker count];
    unsigned long totalBytes = 0;
    for (NSNumber *bytes in uploadBandwidthUsageTracker) {
        totalBytes += [bytes unsignedLongValue];
    }
    if (measurements > 0)
        averageUploadBandwidthUsedPerSecond = totalBytes/measurements;
}

+ (unsigned long)averageDownloadBandwidthUsedPerSecond
{
	[downloadBandwidthThrottlingLock lock];
	unsigned long amount = 	averageDownloadBandwidthUsedPerSecond;
	[downloadBandwidthThrottlingLock unlock];
	return amount;
}

+ (unsigned long)averageUploadBandwidthUsedPerSecond
{
    [uploadBandwidthThrottlingLock lock];
    unsigned long amount = 	averageUploadBandwidthUsedPerSecond;
    [uploadBandwidthThrottlingLock unlock];
    return amount;
}

+ (void)measureDownloadBandwidthUsage
{
	// Other requests may have to wait for this lock if we're sleeping, but this is fine, since in that case we already know they shouldn't be sending or receiving data
	[downloadBandwidthThrottlingLock lock];

	if (!downloadBandwidthMeasurementDate || [downloadBandwidthMeasurementDate timeIntervalSinceNow] < -0) {
		[ASIHTTPRequest recordDownloadBandwidthUsage];
	}
	
	// Are we performing bandwidth throttling?
	if (maxDownloadBandwidthPerSecond) {
		// How much data can we still send or receive this second?
		long long bytesRemaining = (long long)maxDownloadBandwidthPerSecond - (long long)downloadBandwidthUsedInLastSecond;
			
		// Have we used up our allowance?
		if (bytesRemaining < 0) {
			
			// Yes, put this request to sleep until a second is up, with extra added punishment sleeping time for being very naughty (we have used more bandwidth than we were allowed)
			double extraSleepyTime = (-bytesRemaining/(maxDownloadBandwidthPerSecond*1.0));
			[downloadThrottleWakeUpTime release];
			downloadThrottleWakeUpTime = [[NSDate alloc] initWithTimeInterval:extraSleepyTime sinceDate:downloadBandwidthMeasurementDate];
		}
	}
	[downloadBandwidthThrottlingLock unlock];
}

+ (void)measureUploadBandwidthUsage
{
    // Other requests may have to wait for this lock if we're sleeping, but this is fine, since in that case we already know they shouldn't be sending or receiving data
    [uploadBandwidthThrottlingLock lock];

    if (!uploadBandwidthMeasurementDate || [uploadBandwidthMeasurementDate timeIntervalSinceNow] < -0) {
        [ASIHTTPRequest recordUploadBandwidthUsage];
    }

    // Are we performing bandwidth throttling?
    if (maxUploadBandwidthPerSecond) {
        // How much data can we still send or receive this second?
        long long bytesRemaining = (long long)maxUploadBandwidthPerSecond - (long long)uploadBandwidthUsedInLastSecond;

        // Have we used up our allowance?
        if (bytesRemaining < 0) {

            // Yes, put this request to sleep until a second is up, with extra added punishment sleeping time for being very naughty (we have used more bandwidth than we were allowed)
            double extraSleepyTime = (-bytesRemaining/(maxUploadBandwidthPerSecond*1.0));
            [uploadThrottleWakeUpTime release];
            uploadThrottleWakeUpTime = [[NSDate alloc] initWithTimeInterval:extraSleepyTime sinceDate:uploadBandwidthMeasurementDate];
        }
    }
    [uploadBandwidthThrottlingLock unlock];
}

+ (unsigned long)maxUploadReadLength
{
	[uploadBandwidthThrottlingLock lock];
	
	// We'll split our bandwidth allowance into 4 (which is the default for an ASINetworkQueue's max concurrent operations count) to give all running requests a fighting chance of reading data this cycle
	long long toRead = maxUploadBandwidthPerSecond/4;
	if (maxUploadBandwidthPerSecond > 0 && (uploadBandwidthUsedInLastSecond + (unsigned long long)toRead > maxUploadBandwidthPerSecond)) {
		toRead = (long long)maxUploadBandwidthPerSecond-(long long)uploadBandwidthUsedInLastSecond;
		if (toRead < 0) {
			toRead = 0;
		}
	}
	
	if (toRead == 0 || !uploadBandwidthMeasurementDate || [uploadBandwidthMeasurementDate timeIntervalSinceNow] < -0) {
		[uploadThrottleWakeUpTime release];
		uploadThrottleWakeUpTime = [uploadBandwidthMeasurementDate retain];
	}
	[uploadBandwidthThrottlingLock unlock];
	return (unsigned long)toRead;
}

#pragma mark queue

// Returns the shared queue
+ (NSOperationQueue *)sharedQueue
{
    return [[sharedQueue retain] autorelease];
}

#pragma mark network activity

+ (BOOL)isNetworkInUse
{
	[connectionsLock lock];
	BOOL inUse = (runningRequestCount > 0);
	[connectionsLock unlock];
	return inUse;
}

#pragma mark threading behaviour

// In the default implementation, all requests run in a single background thread
// Advanced users only: Override this method in a subclass for a different threading behaviour
// Eg: return [NSThread mainThread] to run all requests in the main thread
// Alternatively, you can create a thread on demand, or manage a pool of threads
// Threads returned by this method will need to run the runloop in default mode (eg CFRunLoopRun())
// Requests will stop the runloop when they complete
// If you have multiple requests sharing the thread or you want to re-use the thread, you'll need to restart the runloop
+ (NSThread *)threadForRequest:(__unused ASIHTTPRequest *)request
{
	if (networkThread == nil) {
		@synchronized(self) {
			if (networkThread == nil) {
				networkThread = [[NSThread alloc] initWithTarget:self selector:@selector(runRequests) object:nil];
				[networkThread start];
			}
		}
	}
	return networkThread;
}

+ (void)runRequests
{
	// Should keep the runloop from exiting
	CFRunLoopSourceContext context = {0, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL};
	CFRunLoopSourceRef source = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context);
	CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopDefaultMode);

    BOOL runAlways = YES; // Introduced to cheat Static Analyzer
	while (runAlways) {
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0e10, true);
		[pool drain];
	}

	// Should never be called, but anyway
	CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, kCFRunLoopDefaultMode);
	CFRelease(source);
}

#pragma mark miscellany 

// Based on hints from http://stackoverflow.com/questions/1850824/parsing-a-rfc-822-date-with-nsdateformatter
+ (NSDate *)dateFromRFC1123String:(NSString *)string
{
	NSDateFormatter *formatter = [[[NSDateFormatter alloc] init] autorelease];
	[formatter setLocale:[[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"] autorelease]];
	// Does the string include a week day?
	NSString *day = @"";
	if ([string rangeOfString:@","].location != NSNotFound) {
		day = @"EEE, ";
	}
	// Does the string include seconds?
	NSString *seconds = @"";
	if ([[string componentsSeparatedByString:@":"] count] == 3) {
		seconds = @":ss";
	}
	[formatter setDateFormat:[NSString stringWithFormat:@"%@dd MMM yyyy HH:mm%@ z",day,seconds]];
	return [formatter dateFromString:string];
}

#pragma mark -
#pragma mark blocks
#if NS_BLOCKS_AVAILABLE
- (void)setStartedBlock:(ASIBasicBlock)aStartedBlock
{
	[startedBlock release];
	startedBlock = [aStartedBlock copy];
}

- (void)setHeadersReceivedBlock:(ASIHeadersBlock)aReceivedBlock
{
	[headersReceivedBlock release];
	headersReceivedBlock = [aReceivedBlock copy];
}

- (void)setCompletionBlock:(ASIBasicBlock)aCompletionBlock
{
	[completionBlock release];
	completionBlock = [aCompletionBlock copy];
}

- (void)setFailedBlock:(ASIBasicBlock)aFailedBlock
{
	[failureBlock release];
	failureBlock = [aFailedBlock copy];
}

- (void)setBytesReceivedBlock:(ASIProgressBlock)aBytesReceivedBlock
{
	[bytesReceivedBlock release];
	bytesReceivedBlock = [aBytesReceivedBlock copy];
}

- (void)setBytesSentBlock:(ASIProgressBlock)aBytesSentBlock
{
	[bytesSentBlock release];
	bytesSentBlock = [aBytesSentBlock copy];
}

- (void)setDownloadSizeIncrementedBlock:(ASISizeBlock)aDownloadSizeIncrementedBlock{
	[downloadSizeIncrementedBlock release];
	downloadSizeIncrementedBlock = [aDownloadSizeIncrementedBlock copy];
}

- (void)setUploadSizeIncrementedBlock:(ASISizeBlock)anUploadSizeIncrementedBlock
{
	[uploadSizeIncrementedBlock release];
	uploadSizeIncrementedBlock = [anUploadSizeIncrementedBlock copy];
}

- (void)setDataReceivedBlock:(ASIDataBlock)aReceivedBlock
{
	[dataReceivedBlock release];
	dataReceivedBlock = [aReceivedBlock copy];
}

- (void)setAuthenticationNeededBlock:(ASIBasicBlock)anAuthenticationBlock
{
	[authenticationNeededBlock release];
	authenticationNeededBlock = [anAuthenticationBlock copy];
}
#endif

#pragma mark ===

@synthesize url;
@synthesize delegate;
@synthesize queue;
@synthesize uploadProgressDelegate;
@synthesize downloadProgressDelegate;
@synthesize downloadDestinationPath;
@synthesize temporaryFileDownloadPath;
@synthesize temporaryUncompressedDataDownloadPath;
@synthesize didStartSelector;
@synthesize didReceiveResponseHeadersSelector;
@synthesize didFinishSelector;
@synthesize didFailSelector;
@synthesize didReceiveDataSelector;
@synthesize error;
@synthesize complete;
@synthesize requestHeaders;
@synthesize responseHeaders;
@synthesize responseCookies;
@synthesize responseStatusCode;
@synthesize rawResponseData;
@synthesize lastActivityTime;
@synthesize timeOutSeconds;
@synthesize requestMethod;
@synthesize postBody;
@synthesize compressedPostBody;
@synthesize contentLength;
@synthesize uploadBufferSize;
@synthesize partialDownloadSize;
@synthesize postLength;
@synthesize shouldResetDownloadProgress;
@synthesize shouldResetUploadProgress;
@synthesize mainRequest;
@synthesize totalBytesRead;
@synthesize totalBytesSent;
@synthesize allowCompressedResponse;
@synthesize allowResumeForFileDownloads;
@synthesize postBodyFilePath;
@synthesize compressedPostBodyFilePath;
@synthesize postBodyWriteStream;
@synthesize postBodyReadStream;
@synthesize shouldStreamPostDataFromDisk;
@synthesize didCreateTemporaryPostDataFile;
@synthesize lastBytesRead;
@synthesize lastBytesSent;
@synthesize cancelledLock;
@synthesize haveBuiltPostBody;
@synthesize fileDownloadOutputStream;
@synthesize inflatedFileDownloadOutputStream;
@synthesize updatedProgress;
@synthesize validatesSecureCertificate;
@synthesize responseStatusMessage;
@synthesize haveBuiltRequestHeaders;
@synthesize inProgress;
@synthesize numberOfTimesToRetryOnTimeout;
@synthesize retryCount;
@synthesize shouldAttemptPersistentConnection;
@synthesize persistentConnectionTimeoutSeconds;
@synthesize connectionCanBeReused;
@synthesize connectionInfo;
@synthesize readStream;
@synthesize readStreamIsScheduled;
@synthesize downloadComplete;
@synthesize requestID;
@synthesize runLoopMode;
@synthesize statusTimer;
@synthesize clientCertificates;
@synthesize dataDecompressor;
@synthesize shouldWaitToInflateCompressedResponses;

@synthesize isSynchronous;
@end
