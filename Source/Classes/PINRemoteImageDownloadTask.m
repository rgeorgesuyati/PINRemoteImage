//
//  PINRemoteImageDownloadTask.m
//  Pods
//
//  Created by Garrett Moon on 3/9/15.
//
//

#import "PINRemoteImageDownloadTask.h"

#import "PINRemoteImageTask+Subclassing.h"
#import "PINRemoteImage.h"
#import "PINRemoteImageCallbacks.h"
#import "PINRemoteLock.h"

#define PINRemoteImageMaxRetries                       3
#define PINRemoteImageRetryDelayBase                   4

@interface PINRemoteImageDownloadTask ()
{
    PINProgressiveImage *_progressImage;
}

@end

@implementation PINRemoteImageDownloadTask

- (instancetype)initWithManager:(PINRemoteImageManager *)manager
{
    if (self = [super initWithManager:manager]) {
        _numberOfRetries = 0;
    }
    return self;
}

- (void)callProgressDownload
{
    NSDictionary *callbackBlocks = self.callbackBlocks;
    #if PINRemoteImageLogging
    NSString *key = self.key;
    #endif
    
    __block int64_t completedBytes;
    __block int64_t totalBytes;
    
    [self.lock lockWithBlock:^{
        completedBytes = _progressImage.dataTask.countOfBytesReceived;
        totalBytes = _progressImage.dataTask.countOfBytesExpectedToReceive;
    }];
    
    [callbackBlocks enumerateKeysAndObjectsUsingBlock:^(NSUUID *UUID, PINRemoteImageCallbacks *callback, BOOL *stop) {
        if (callback.progressDownloadBlock != nil) {
            PINLog(@"calling progress for UUID: %@ key: %@", UUID, key);
            PINRemoteImageManagerProgressDownload progressDownloadBlock = callback.progressDownloadBlock;
            //The code run asynchronously below is *not* guaranteed to be run in the manager's lock!
            //All access to the callbacks and self should be done outside the block below!
            dispatch_async(self.manager.callbackQueue, ^
            {
                progressDownloadBlock(completedBytes, totalBytes);
            });
        }
    }];
}

- (void)callProgressImageWithImage:(nonnull PINImage *)image renderedImageQuality:(CGFloat)renderedImageQuality
{
    NSDictionary *callbackBlocks = self.callbackBlocks;
#if PINRemoteImageLogging
    NSString *key = self.key;
#endif
    
    
    [callbackBlocks enumerateKeysAndObjectsUsingBlock:^(NSUUID *UUID, PINRemoteImageCallbacks *callback, BOOL *stop) {
        if (callback.progressImageBlock != nil) {
            PINLog(@"calling progress for UUID: %@ key: %@", UUID, key);
            PINRemoteImageManagerImageCompletion progressImageBlock = callback.progressImageBlock;
            CFTimeInterval requestTime = callback.requestTime;
            //The code run asynchronously below is *not* guaranteed to be run in the manager's lock!
            //All access to the callbacks and self should be done outside the block below!
            dispatch_async(self.manager.callbackQueue, ^
            {
                progressImageBlock([PINRemoteImageManagerResult imageResultWithImage:image
                                                           alternativeRepresentation:nil
                                                                       requestLength:CACurrentMediaTime() - requestTime
                                                                               error:nil
                                                                          resultType:PINRemoteImageResultTypeProgress
                                                                                UUID:UUID
                                                                renderedImageQuality:renderedImageQuality]);
           });
        }
    }];
}

- (BOOL)cancelWithUUID:(NSUUID *)UUID resume:(PINResume * _Nullable * _Nullable)resume
{
    __block BOOL noMoreCompletions;
    [self.lock lockWithBlock:^{
        noMoreCompletions = [super __locked_cancelWithUUID:UUID resume:resume];
        
        if (noMoreCompletions) {
            [self.manager.urlSessionTaskQueue removeDownloadTaskFromQueue:_progressImage.dataTask];
            [_progressImage.dataTask cancel];
            
            if (resume && _ifRange && _totalBytes > 0) {
                NSData *progressData = _progressImage.data;
                if (progressData.length > 0) {
                    *resume = [PINResume resumeData:progressData ifRange:_ifRange totalBytes:_totalBytes];
                }
            }
            
            PINLog(@"Canceling download of URL: %@, UUID: %@", _progressImage.dataTask.originalRequest.URL, UUID);
        }
#if PINRemoteImageLogging
        else {
            PINLog(@"Decrementing download of URL: %@, UUID: %@", _progressImage.dataTask.originalRequest.URL, UUID);
        }
#endif
    }];
    
    return noMoreCompletions;
}

- (void)setPriority:(PINRemoteImageManagerPriority)priority
{
    [super setPriority:priority];
    if (PINNSURLSessionTaskSupportsPriority) {
        [self.lock lockWithBlock:^{
            if (_progressImage.dataTask) {
                _progressImage.dataTask.priority = dataTaskPriorityWithImageManagerPriority(priority);
                [self.manager.urlSessionTaskQueue setQueuePriority:priority forTask:_progressImage.dataTask];
            }
        }];
    }
}

- (NSURL *)URL
{
    __block NSURL *url;
    [self.lock lockWithBlock:^{
        url = _progressImage.dataTask.originalRequest.URL;
    }];
    return url;
}

- (nonnull PINRemoteImageManagerResult *)imageResultWithImage:(nullable PINImage *)image
                                    alternativeRepresentation:(nullable id)alternativeRepresentation
                                                requestLength:(NSTimeInterval)requestLength
                                                        error:(nullable NSError *)error
                                                   resultType:(PINRemoteImageResultType)resultType
                                                         UUID:(nullable NSUUID *)UUID
{
    NSUInteger bytesSavedByResuming = self.resume.resumeData.length;
    return [PINRemoteImageManagerResult imageResultWithImage:image
                                   alternativeRepresentation:alternativeRepresentation
                                               requestLength:requestLength
                                                       error:error
                                                  resultType:resultType
                                                        UUID:UUID
                                        bytesSavedByResuming:bytesSavedByResuming];
}

- (void)didReceiveData:(NSData *_Nonnull)data
{
    [self callProgressDownload];
    
    __block int64_t expectedNumberOfBytes;
    [self.lock lockWithBlock:^{
        expectedNumberOfBytes = _progressImage.dataTask.countOfBytesExpectedToReceive;
    }];
    
    [self updateData:data isResume:NO expectedBytes:expectedNumberOfBytes];
}

- (void)updateData:(NSData *)data isResume:(BOOL)isResume expectedBytes:(int64_t)expectedBytes
{
    __block PINProgressiveImage *progressImage;
    __block BOOL hasProgressBlocks = NO;
    [self.lock lockWithBlock:^{
        progressImage = _progressImage;
        [[self __locked_callbackBlocks] enumerateKeysAndObjectsUsingBlock:^(NSUUID *UUID, PINRemoteImageCallbacks *callback, BOOL *stop) {
            if (callback.progressImageBlock) {
                hasProgressBlocks = YES;
                *stop = YES;
            }
        }];
    }];
    
    [progressImage updateProgressiveImageWithData:data expectedNumberOfBytes:expectedBytes isResume:isResume];
    
    if (hasProgressBlocks) {
        if (PINNSOperationSupportsBlur) {
            weakify(self);
            [self.manager.concurrentOperationQueue addOperation:^{
                strongify(self);
                CGFloat renderedImageQuality = 1.0;
                PINImage *image = [progressImage currentImageBlurred:self.manager.shouldBlurProgressive maxProgressiveRenderSize:self.manager.maxProgressiveRenderSize renderedImageQuality:&renderedImageQuality];
                if (image) {
                    [self callProgressImageWithImage:image renderedImageQuality:renderedImageQuality];
                }
            } withPriority:PINOperationQueuePriorityLow];
        }
    }
}

- (void)didReceiveResponse:(nonnull NSURLResponse *)response
{
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        
        // Got partial data back for a resume
        if (httpResponse.statusCode == 206) {
            __block PINResume *resume;
            [self.lock lockWithBlock:^{
                resume = self.resume;
            }];
            
            [self updateData:resume.resumeData isResume:YES expectedBytes:resume.totalBytes];
        } else {
            //Check if there's resume data and we didn't get back a 206, get rid of it
            self.resume = nil;
        }
        
        // Check to see if the server supports resume
        if ([[httpResponse allHeaderFields][@"Accept-Ranges"] isEqualToString:@"bytes"]) {
            NSString *ifRange = nil;
            NSString *etag = nil;
            
            if ((etag = [httpResponse allHeaderFields][@"ETag"])) {
                if ([etag hasPrefix:@"W/"] == NO) {
                    ifRange = etag;
                }
            } else {
                ifRange = [httpResponse allHeaderFields][@"Last-Modified"];
            }
            
            if (ifRange.length > 0) {
                [self.lock lockWithBlock:^{
                    _ifRange = ifRange;
                    _totalBytes = httpResponse.expectedContentLength;
                }];
            }
        }
    }
}

- (void)scheduleDownloadWithRequest:(NSURLRequest *)request
                             resume:(PINResume *)resume
                          skipRetry:(BOOL)skipRetry
                           priority:(PINRemoteImageManagerPriority)priority
                  completionHandler:(PINRemoteImageManagerDataCompletion)completionHandler
{
    [self.lock lockWithBlock:^{
        if (_progressImage != nil || [self __locked_callbackBlocks].count == 0 || _numberOfRetries > 0) {
            return;
        }
        _resume = resume;
        
        NSURLRequest *adjustedRequest = request;
        if (_resume) {
            NSMutableURLRequest *mutableRequest = [request mutableCopy];
            NSMutableDictionary *headers = [[mutableRequest allHTTPHeaderFields] mutableCopy];
            headers[@"If-Range"] = _resume.ifRange;
            headers[@"Range"] = [NSString stringWithFormat:@"bytes=%tu-", _resume.resumeData.length];
            mutableRequest.allHTTPHeaderFields = headers;
            adjustedRequest = mutableRequest;
        }
        
        _progressImage = [[PINProgressiveImage alloc] initWithDataTask:[self.manager.urlSessionTaskQueue addDownloadWithSessionManager:self.manager.sessionManager
                                                                                                                               request:adjustedRequest
                                                                                                                              priority:priority
                                                                                                                     completionHandler:^(NSURLResponse * _Nonnull response, NSError * _Nonnull remoteError)
        {
            [self.manager.concurrentOperationQueue addOperation:^{
                NSError *error = remoteError;
#if PINRemoteImageLogging
                if (error && error.code != NSURLErrorCancelled) {
                    PINLog(@"Failed downloading image: %@ with error: %@", url, error);
                } else if (error == nil && response.expectedContentLength == 0) {
                    PINLog(@"image is empty at URL: %@", url);
                } else {
                    PINLog(@"Finished downloading image: %@", url);
                }
#endif
                
                if (error.code != NSURLErrorCancelled) {
                    NSData *data = self.progressImage.data;
                    
                    if (error == nil && data == nil) {
                        error = [NSError errorWithDomain:PINRemoteImageManagerErrorDomain
                                                    code:PINRemoteImageManagerErrorImageEmpty
                                                userInfo:nil];
                    }
                    
                    if (error && [[self class] retriableError:error]) {
                        //attempt to retry after delay
                        __block BOOL retry = NO;
                        __block NSUInteger newNumberOfRetries = 0;
                        [self.lock lockWithBlock:^{
                            if (_numberOfRetries < PINRemoteImageMaxRetries && skipRetry == NO) {
                                retry = YES;
                                newNumberOfRetries = ++_numberOfRetries;
                                
                                // Clear out the exsiting progress image or else new data from retry will be appended
                                _progressImage = nil;
                            }
                        }];
                        
                        if (retry) {
                            int64_t delay = powf(PINRemoteImageRetryDelayBase, newNumberOfRetries);
                            PINLog(@"Retrying download of %@ in %d seconds.", URL, delay);
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                                [self.lock lockWithBlock:^{
                                    if (_progressImage == nil && [self __locked_callbackBlocks].count > 0) {
                                        //If completionBlocks.count == 0, we've canceled before we were even able to start.
                                        //If there was an error, do not attempt to use resume data
                                        [self scheduleDownloadWithRequest:request resume:nil skipRetry:skipRetry priority:priority completionHandler:completionHandler];
                                    }
                                }];
                            });
                            return;
                        }
                    }
                    
                    completionHandler(data, error);
                }
            }];
        }]];
        
        if (PINNSURLSessionTaskSupportsPriority) {
            _progressImage.dataTask.priority = dataTaskPriorityWithImageManagerPriority(priority);
        }
    }];
}

- (PINProgressiveImage *)progressImage
{
    __block PINProgressiveImage *progressImage = nil;
    [self.lock lockWithBlock:^{
        progressImage = _progressImage;
    }];
    return progressImage;
}

+ (BOOL)retriableError:(NSError *)remoteImageError
{
    if ([remoteImageError.domain isEqualToString:PINURLErrorDomain]) {
        return remoteImageError.code >= 500;
    } else if ([remoteImageError.domain isEqualToString:NSURLErrorDomain] && remoteImageError.code == NSURLErrorUnsupportedURL) {
        return NO;
    } else if ([remoteImageError.domain isEqualToString:PINRemoteImageManagerErrorDomain]) {
        return NO;
    }
    return YES;
}

- (float)bytesPerSecond
{
    return self.progressImage.bytesPerSecond;
}

- (CFTimeInterval)estimatedRemainingTime
{
    return self.progressImage.estimatedRemainingTime;
}

- (NSData *)data
{
    return self.progressImage.data;
}

@end
