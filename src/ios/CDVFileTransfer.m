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

#import <Cordova/CDV.h>
#import "CDVFileTransfer.h"
#import "CDVLocalFilesystem.h"

#import <AssetsLibrary/ALAsset.h>
#import <AssetsLibrary/ALAssetRepresentation.h>
#import <AssetsLibrary/ALAssetsLibrary.h>
#import <CFNetwork/CFNetwork.h>

#ifndef DLog
#ifdef DEBUG
    #define DLog(fmt, ...) NSLog((@"%s [Line %d] " fmt), __PRETTY_FUNCTION__, __LINE__, ##__VA_ARGS__)
#else
    #define DLog(...)
#endif
#endif

@interface CDVFileTransfer ()
// Sets the requests headers for the request.
- (void)applyRequestHeaders:(NSDictionary*)headers toRequest:(NSMutableURLRequest*)req;
// Creates a delegate to handle an upload.
- (CDVFileTransferDelegate*)delegateForUploadCommand:(CDVInvokedUrlCommand*)command;
// Creates an NSData* for the file for the given upload arguments.
- (void)fileDataForUploadCommand:(CDVInvokedUrlCommand*)command;
@end

// Buffer size to use for streaming uploads.
static const NSUInteger kStreamBufferSize = 32768;
// Magic value within the options dict used to set a cookie.
NSString* const kOptionsKeyCookie = @"__cookie";
// Form boundary for multi-part requests.
NSString* const kFormBoundary = @"+++++org.apache.cordova.formBoundary";

// Writes the given data to the stream in a blocking way.
// If successful, returns bytesToWrite.
// If the stream was closed on the other end, returns 0.
// If there was an error, returns -1.
static CFIndex WriteDataToStream(NSData* data, CFWriteStreamRef stream)
{
    UInt8* bytes = (UInt8*)[data bytes];
    long long bytesToWrite = [data length];
    long long totalBytesWritten = 0;
    while (totalBytesWritten < bytesToWrite) {
        CFIndex result = CFWriteStreamWrite(stream,
                bytes + totalBytesWritten,
                bytesToWrite - totalBytesWritten);
        if (result < 0) {
            CFStreamError error = CFWriteStreamGetError(stream);
            NSLog(@"WriteStreamError domain: %ld error: %ld", error.domain, (long)error.error);
            return result;
        } else if (result == 0) {
            return result;
        }
        totalBytesWritten += result;
    }
    return totalBytesWritten;
}

@implementation CDVFileTransfer
@synthesize activeTransfers;

- (void)pluginInitialize {
    activeTransfers = [[NSMutableDictionary alloc] init];
}

- (CFIndex)WriteDataToStream:(NSData*)data myStream:(CFWriteStreamRef)stream delegate:(CDVFileTransferDelegate*)delegate
{
    UInt8* bytes = (UInt8*)[data bytes];
    long long bytesToWrite = [data length];
    long long totalBytesWritten = 0;
    
    while (totalBytesWritten < bytesToWrite) {
        if(delegate.paused) {
            NSLog(@"用户已暂停传输，中止上传...");
            break;
        }
        CFIndex result = CFWriteStreamWrite(stream,
                                            bytes + totalBytesWritten,
                                            bytesToWrite - totalBytesWritten);
        if (result < 0) {
            CFStreamError error = CFWriteStreamGetError(stream);
            NSLog(@"WriteStreamError domain: %ld error: %ld", error.domain, (long)error.error);
            return result;
        } else if (result == 0) {
            return result;
        }
        totalBytesWritten += result;
    }
    
    return totalBytesWritten;
}

- (NSString*)escapePathComponentForUrlString:(NSString*)urlString
{
    NSRange schemeAndHostRange = [urlString rangeOfString:@"://.*?/" options:NSRegularExpressionSearch];

    if (schemeAndHostRange.length == 0) {
        return urlString;
    }

    NSInteger schemeAndHostEndIndex = NSMaxRange(schemeAndHostRange);
    NSString* schemeAndHost = [urlString substringToIndex:schemeAndHostEndIndex];
    NSString* pathComponent = [urlString substringFromIndex:schemeAndHostEndIndex];
    pathComponent = [pathComponent stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];

    return [schemeAndHost stringByAppendingString:pathComponent];
}

- (void)applyRequestHeaders:(NSDictionary*)headers toRequest:(NSMutableURLRequest*)req
{
    [req setValue:@"XMLHttpRequest" forHTTPHeaderField:@"X-Requested-With"];

    NSString* userAgent = [self.commandDelegate userAgent];
    if (userAgent) {
        [req setValue:userAgent forHTTPHeaderField:@"User-Agent"];
    }

    for (NSString* headerName in headers) {
        id value = [headers objectForKey:headerName];
        if (!value || (value == [NSNull null])) {
            value = @"null";
        }

        // First, remove an existing header if one exists.
        [req setValue:nil forHTTPHeaderField:headerName];

        if (![value isKindOfClass:[NSArray class]]) {
            value = [NSArray arrayWithObject:value];
        }

        // Then, append all header values.
        for (id __strong subValue in value) {
            // Convert from an NSNumber -> NSString.
            if ([subValue respondsToSelector:@selector(stringValue)]) {
                subValue = [subValue stringValue];
            }
            if ([subValue isKindOfClass:[NSString class]]) {
                [req addValue:subValue forHTTPHeaderField:headerName];
            }
        }
    }
}

- (NSURLRequest*)requestForUploadCommand:(CDVInvokedUrlCommand*)command fileData:(NSData*)fileData offset:(long long)offset delegate:(CDVFileTransferDelegate*)delegate
{
    // arguments order from js: [filePath, server, fileKey, fileName, mimeType, params, debug, chunkedMode]
    // however, params is a JavaScript object and during marshalling is put into the options dict,
    // thus debug and chunkedMode are the 6th and 7th arguments
    NSString* target = [command argumentAtIndex:0];
    NSString* server = [command argumentAtIndex:1]; 
    NSString* fileKey = [command argumentAtIndex:2 withDefault:@"file"];
    NSString* fileName = [command argumentAtIndex:3 withDefault:@"image.jpg"];
    NSString* mimeType = [command argumentAtIndex:4 withDefault:@"image/jpeg"];
    NSDictionary* options = [command argumentAtIndex:5 withDefault:nil];
    //    BOOL trustAllHosts = [[command argumentAtIndex:6 withDefault:[NSNumber numberWithBool:YES]] boolValue]; // allow self-signed certs
    BOOL chunkedMode = [[command argumentAtIndex:7 withDefault:[NSNumber numberWithBool:YES]] boolValue];
    NSDictionary* headers = [command argumentAtIndex:8 withDefault:nil];
    // Allow alternative http method, default to POST. JS side checks
    // for allowed methods, currently PUT or POST (forces POST for
    // unrecognised values)
    NSString* httpMethod = [command argumentAtIndex:10 withDefault:@"POST"];
    CDVPluginResult* result = nil;
    CDVFileTransferError errorCode = 0;

    // NSURL does not accepts URLs with spaces in the path. We escape the path in order
    // to be more lenient.
    NSURL* url = [NSURL URLWithString:server];

    if (!url) {
        errorCode = INVALID_URL_ERR;
        NSLog(@"File Transfer Error: Invalid server URL %@", server);
    } else if (!fileData) {
        errorCode = FILE_NOT_FOUND_ERR;
    }

    if (errorCode > 0) {
        result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:[self createFileTransferError:errorCode AndSource:target AndTarget:server]];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        return nil;
    }

    NSMutableURLRequest* req = [NSMutableURLRequest requestWithURL:url];

    [req setHTTPMethod:httpMethod];

    //    Magic value to set a cookie
    if ([options objectForKey:kOptionsKeyCookie]) {
        [req setValue:[options objectForKey:kOptionsKeyCookie] forHTTPHeaderField:@"Cookie"];
        [req setHTTPShouldHandleCookies:NO];
    }

    // if we specified a Content-Type header, don't do multipart form upload
    BOOL multipartFormUpload = [headers objectForKey:@"Content-Type"] == nil;
    if (multipartFormUpload) {
        NSString* contentType = [NSString stringWithFormat:@"multipart/form-data; boundary=%@", kFormBoundary];
        [req setValue:contentType forHTTPHeaderField:@"Content-Type"];
    }
    [self applyRequestHeaders:headers toRequest:req];

    NSData* formBoundaryData = [[NSString stringWithFormat:@"--%@\r\n", kFormBoundary] dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableData* postBodyBeforeFile = [NSMutableData data];

    for (NSString* key in options) {
        id val = [options objectForKey:key];
        if (!val || (val == [NSNull null]) || [key isEqualToString:kOptionsKeyCookie]) {
            continue;
        }
        // if it responds to stringValue selector (eg NSNumber) get the NSString
        if ([val respondsToSelector:@selector(stringValue)]) {
            val = [val stringValue];
        }
        // finally, check whether it is a NSString (for dataUsingEncoding selector below)
        if (![val isKindOfClass:[NSString class]]) {
            continue;
        }

        [postBodyBeforeFile appendData:formBoundaryData];
        [postBodyBeforeFile appendData:[[NSString stringWithFormat:@"Content-Disposition: form-data; name=\"%@\"\r\n\r\n", key] dataUsingEncoding:NSUTF8StringEncoding]];
        [postBodyBeforeFile appendData:[val dataUsingEncoding:NSUTF8StringEncoding]];
        [postBodyBeforeFile appendData:[@"\r\n" dataUsingEncoding : NSUTF8StringEncoding]];
    }
    
    //断点模式，传入上传起始位置......
    [postBodyBeforeFile appendData:formBoundaryData];
    [postBodyBeforeFile appendData:[[NSString stringWithFormat:@"Content-Disposition: form-data; name=\"%@\"\r\n\r\n", @"range"] dataUsingEncoding:NSUTF8StringEncoding]];
    long long length = [fileData length] + offset;
    NSString* range =  [NSString stringWithFormat:@"%lld-%lld-%lld", offset, length - 1, length];
    [postBodyBeforeFile appendData:[range dataUsingEncoding:NSUTF8StringEncoding]];
    [postBodyBeforeFile appendData:[@"\r\n" dataUsingEncoding : NSUTF8StringEncoding]];

    NSLog(@"range信息: %@", range);
    
    [postBodyBeforeFile appendData:formBoundaryData];
    [postBodyBeforeFile appendData:[[NSString stringWithFormat:@"Content-Disposition: form-data; name=\"%@\"; filename=\"%@\"\r\n", fileKey, fileName] dataUsingEncoding:NSUTF8StringEncoding]];
    if (mimeType != nil) {
        [postBodyBeforeFile appendData:[[NSString stringWithFormat:@"Content-Type: %@\r\n", mimeType] dataUsingEncoding:NSUTF8StringEncoding]];
    }
    [postBodyBeforeFile appendData:[[NSString stringWithFormat:@"Content-Length: %ld\r\n\r\n", (long)[fileData length]] dataUsingEncoding:NSUTF8StringEncoding]];

    DLog(@"fileData length: %ld", [fileData length]);
    NSData* postBodyAfterFile = [[NSString stringWithFormat:@"\r\n--%@--\r\n", kFormBoundary] dataUsingEncoding:NSUTF8StringEncoding];

    long long totalPayloadLength = [fileData length];
    if (multipartFormUpload) {
        totalPayloadLength += [postBodyBeforeFile length] + [postBodyAfterFile length];
    }

    [req setValue:[[NSNumber numberWithLongLong:totalPayloadLength] stringValue] forHTTPHeaderField:@"Content-Length"];

    if (chunkedMode) {
        CFReadStreamRef readStream = NULL;
        CFWriteStreamRef writeStream = NULL;
        CFStreamCreateBoundPair(NULL, &readStream, &writeStream, kStreamBufferSize);
        [req setHTTPBodyStream:CFBridgingRelease(readStream)];

        [self.commandDelegate runInBackground:^{
            if (CFWriteStreamOpen(writeStream)) {
                if (multipartFormUpload) {
                    NSData* chunks[] = { postBodyBeforeFile, fileData };
                    int numChunks = sizeof(chunks) / sizeof(chunks[0]);
                    NSLog(@"chunks数目:%d, %ld, %ld", numChunks, sizeof(chunks), sizeof(chunks[0]));
                    for (int i = 0; i < numChunks; ++i) {
                        // Allow uploading of an empty file
                        if (chunks[i].length == 0) {
                            continue;
                        }
                        
                        NSLog(@"delegate:%d, %@, %@", delegate.paused, delegate.business, delegate.source);
                        CFIndex result = [self WriteDataToStream:chunks[i] myStream:writeStream delegate:delegate];
                        if (result <= 0) {
                            break;
                        }
                    }
                    
                    WriteDataToStream(postBodyAfterFile, writeStream);
                } else {
                    if (totalPayloadLength > 0) {
                        WriteDataToStream(fileData, writeStream);
                    } else {
                        NSLog(@"Uploading of an empty file is not supported for chunkedMode=true and multipart=false");
                    }
                }
            } else {
                NSLog(@"FileTransfer: Failed to open writeStream");
            }
            CFWriteStreamClose(writeStream);
            CFRelease(writeStream);
            NSLog(@"Upload finished......");
        }];
    } else {
        if (multipartFormUpload) {
            [postBodyBeforeFile appendData:fileData];
            [postBodyBeforeFile appendData:postBodyAfterFile];
            [req setHTTPBody:postBodyBeforeFile];
        } else {
            [req setHTTPBody:fileData];
        }
    }
    return req;
}

- (CDVFileTransferDelegate*)delegateForUploadCommand:(CDVInvokedUrlCommand*)command offset:(long long)offset
{
    NSString* source = [command argumentAtIndex:0];
    NSString* server = [command argumentAtIndex:1];
    BOOL trustAllHosts = [[command argumentAtIndex:6 withDefault:[NSNumber numberWithBool:NO]] boolValue]; // allow self-signed certs
    NSString* objectId = [command argumentAtIndex:9];
    BOOL chunkedMode = [[command argumentAtIndex:7 withDefault:[NSNumber numberWithBool:YES]] boolValue];

    CDVFileTransferDelegate* delegate = [[CDVFileTransferDelegate alloc] init];

    delegate.command = self;
    delegate.callbackId = command.callbackId;
    delegate.direction = CDV_TRANSFER_UPLOAD;
    delegate.objectId = objectId;
    delegate.source = source;
    delegate.target = server;
    delegate.trustAllHosts = trustAllHosts;
    delegate.filePlugin = [self.commandDelegate getCommandInstance:@"File"];
    delegate.chunkedMode = chunkedMode;
    delegate.business = @"upload";
    delegate.offset = offset;

    return delegate;
}

- (void)fileDataForUploadCommand:(CDVInvokedUrlCommand*)command
{
    NSLog(@"fileDataForUploadCommand......");
    NSString* source = (NSString*)[command argumentAtIndex:0];
    NSString* server = [command argumentAtIndex:1];
    NSError* __autoreleasing err = nil;

    NSDictionary* params = (NSDictionary*)[command argumentAtIndex:5];
//    for(NSString *key in [params allKeys]) {
//        NSLog(@"key: %@ = %@", key, [params objectForKey:key]);
//    }
    
    if ([source hasPrefix:@"data:"] && [source rangeOfString:@"base64"].location != NSNotFound) {
        NSRange commaRange = [source rangeOfString: @","];
        if (commaRange.location == NSNotFound) {
            // Return error is there is no comma
            __weak CDVFileTransfer* weakSelf = self;
            CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:[weakSelf createFileTransferError:INVALID_URL_ERR AndSource:source AndTarget:server]];
            [weakSelf.commandDelegate sendPluginResult:result callbackId:command.callbackId];
            return;
        }

        if (commaRange.location + 1 > source.length - 1) {
            // Init as an empty data
            NSData *fileData = [[NSData alloc] init];
            [self uploadData:fileData command:command offset:0];
            return;
        }

        NSData *fileData = [[NSData alloc] initWithBase64EncodedString:[source substringFromIndex:(commaRange.location + 1)] options:NSDataBase64DecodingIgnoreUnknownCharacters];
        [self uploadData:fileData command:command offset:0];
        return;
    }

    CDVFilesystemURL *sourceURL = [CDVFilesystemURL fileSystemURLWithString:source];
    NSObject<CDVFileSystem> *fs;
    if (sourceURL) {
        // Try to get a CDVFileSystem which will handle this file.
        // This requires talking to the current CDVFile plugin.
        fs = [[self.commandDelegate getCommandInstance:@"File"] filesystemForURL:sourceURL];
    }
    
    //读取偏移量
    long long offset = [[params valueForKey:@"offset"] longLongValue];
    NSLog(@"传入offset值为：%lld", offset);
    
    if (fs) {
        __weak CDVFileTransfer* weakSelf = self;
        //修改：读位置起始处设置为offset
        [fs readFileAtURL:sourceURL start:offset end:-1 callback:^(NSData *fileData, NSString *mimeType, CDVFileError err) {
            if (err) {
                // We couldn't find the asset.  Send the appropriate error.
                CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:[weakSelf createFileTransferError:NOT_FOUND_ERR AndSource:source AndTarget:server]];
                [weakSelf.commandDelegate sendPluginResult:result callbackId:command.callbackId];
            }  else {
                [weakSelf uploadData:fileData command:command offset:offset];
            }
        }];
        return;
    } else {
        // Extract the path part out of a file: URL.
        NSString* filePath = [source hasPrefix:@"/"] ? [source copy] : [(NSURL *)[NSURL URLWithString:source] path];
        if (filePath == nil) {
            // We couldn't find the asset.  Send the appropriate error.
            CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:[self createFileTransferError:NOT_FOUND_ERR AndSource:source AndTarget:server]];
            [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
            return;
        }

        // Memory map the file so that it can be read efficiently even if it is large.
        NSData* fileDataAll = [NSData dataWithContentsOfFile:filePath options:NSDataReadingMappedIfSafe error:&err];

        if (err != nil) {
            NSLog(@"Error opening file %@: %@", source, err);
            CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:[self createFileTransferError:NOT_FOUND_ERR AndSource:source AndTarget:server]];
            [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        } else {
            NSData* fileData = [fileDataAll subdataWithRange:NSMakeRange(offset, [fileDataAll length] - offset)];
            [self uploadData:fileData command:command offset:offset];
        }
    }
}

- (void)upload:(CDVInvokedUrlCommand*)command
{
    // fileData and req are split into helper functions to ease the unit testing of delegateForUpload.
    // First, get the file data.  This method will call `uploadData:command`.
    [self fileDataForUploadCommand:command];
}

- (void)uploadData:(NSData*)fileData command:(CDVInvokedUrlCommand*)command offset:(long long)offset
{
    CDVFileTransferDelegate* delegate = [self delegateForUploadCommand:command offset:offset];
    NSURLRequest* req = [self requestForUploadCommand:command fileData:fileData offset:offset delegate:delegate];
    NSLog(@"uploadData.....");
    if (req == nil) {
        return;
    }
    delegate.connection = [[NSURLConnection alloc] initWithRequest:req delegate:delegate startImmediately:NO];
    if (self.queue == nil) {
        self.queue = [[NSOperationQueue alloc] init];
    }
    [delegate.connection setDelegateQueue:self.queue];

    // sets a background task ID for the transfer object.
    delegate.backgroundTaskID = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
        [delegate cancelTransfer:delegate.connection];
    }];

    @synchronized (activeTransfers) {
        activeTransfers[delegate.objectId] = delegate;
    }
    [delegate.connection start];
}

- (void)abort:(CDVInvokedUrlCommand*)command
{
    NSString* objectId = [command argumentAtIndex:0];

    @synchronized (activeTransfers) {
        CDVFileTransferDelegate* delegate = activeTransfers[objectId];
        if (delegate != nil) {
            [delegate cancelTransfer:delegate.connection];
            CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:[self createFileTransferError:CONNECTION_ABORTED AndSource:delegate.source AndTarget:delegate.target]];
            [self.commandDelegate sendPluginResult:result callbackId:delegate.callbackId];
        }
    }
}

- (void)pause:(CDVInvokedUrlCommand*)command
{
    NSString* objectId = [command argumentAtIndex:0];
    @synchronized (activeTransfers) {
        NSLog(@"pause objectid:%@", objectId);
        CDVFileTransferDelegate* delegate = activeTransfers[objectId];
        if (delegate != nil) {
            NSLog(@"用户暂停文件传输....%@", delegate.source);
            delegate.paused = true;

            if(delegate.direction == CDV_TRANSFER_DOWNLOAD) {
                [delegate cancelTransferOnPause:delegate.connection];
                [delegate setProgress:false];
            }
            
        }
        
    }}

- (void)download:(CDVInvokedUrlCommand*)command
{
    DLog(@"File Transfer downloading file...");
    NSString* source = [command argumentAtIndex:0];
    NSString* target = [command argumentAtIndex:1];
    BOOL trustAllHosts = [[command argumentAtIndex:2 withDefault:[NSNumber numberWithBool:NO]] boolValue]; // allow self-signed certs
    NSString* objectId = [command argumentAtIndex:3];
    NSMutableDictionary* headers = [command argumentAtIndex:4 withDefault:nil];
    NSDictionary* params = [command argumentAtIndex:5 withDefault:nil];

    long long offset = [[params valueForKey:@"offset"] longLongValue];
    long long total = [[params valueForKey:@"total"] longLongValue];
	NSLog(@"File offset: %lld, file total: %lld", offset, total);

    CDVPluginResult* result = nil;
    CDVFileTransferError errorCode = 0;

    NSURL* targetURL;
    NSURL* sourceURL = [NSURL URLWithString:source];
    NSString* name = [NSString stringWithFormat:@"%@%@%lld%@%lld%@", target, @".[Range==bytes=0-", offset - 1, @"=Total==", total, @"].downloading"];
//    NSString* name = target;
 //   name = [name stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLHostAllowedCharacterSet]];
//    NSURL* tmpTargetURL = [[self.commandDelegate getCommandInstance:@"File"] fileSystemURLforLocalPath:name].url;

//    //查找文件，矫正offset的位置。。。。
//    NSFileManager *fileManager = [NSFileManager defaultManager];
//    if ([fileManager fileExistsAtPath:name]){
//        offset = [[fileManager attributesOfItemAtPath:name error:nil] fileSize];
//        NSLog(@"File offset is set to %lld", offset);
//    } else {
//        offset = 0;
//        NSLog(@"File offset is set to %lld", offset);
//    }
    [headers setValue:[NSString stringWithFormat:@"%@%lld%@", @"bytes=", offset, @"-"] forKey:@"Range"];

    //targetURL规范化......
    if ([name hasPrefix:@"/"]) {
        /* Backwards-compatibility:
         * Check here to see if it looks like the user passed in a raw filesystem path. (Perhaps they had the path saved, and were previously using it with the old version of File). If so, normalize it by removing empty path segments, and check with File to see if any of the installed filesystems will handle it. If so, then we will end up with a filesystem url to use for the remainder of this operation.
         */
        name = [target stringByReplacingOccurrencesOfString:@"//" withString:@"/"];
        targetURL = [[self.commandDelegate getCommandInstance:@"File"] fileSystemURLforLocalPath:name].url;
    } else {
        targetURL = [NSURL URLWithString:name];
        if (targetURL == nil) {
            NSString* targetUrlTextEscaped = [name stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLFragmentAllowedCharacterSet]];
            if (targetUrlTextEscaped) {
                targetURL = [NSURL URLWithString:targetUrlTextEscaped];
            }
        }
    }
    
    //参数检查校验...
    if (!sourceURL) {
        errorCode = INVALID_URL_ERR;
        NSLog(@"File Transfer Error: Invalid server URL %@", source);
    } else if (!targetURL) {
        errorCode = INVALID_URL_ERR;
        NSLog(@"File Tranfer Error: Invalid target URL %@", target);
    } else if (![targetURL isFileURL]) {
        CDVFilesystemURL *fsURL = [CDVFilesystemURL fileSystemURLWithString:target];
        if (!fsURL) {
            errorCode = FILE_NOT_FOUND_ERR;
            NSLog(@"File Transfer Error: Invalid file path or URL %@", target);
        }
    }
    if (errorCode > 0) {
        result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:[self createFileTransferError:errorCode AndSource:source AndTarget:target]];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        return;
    }

    NSMutableURLRequest* req = [NSMutableURLRequest requestWithURL:sourceURL];
    [self applyRequestHeaders:headers toRequest:req];

    CDVFileTransferDelegate* delegate = [[CDVFileTransferDelegate alloc] init];
    delegate.command = self;
    delegate.direction = CDV_TRANSFER_DOWNLOAD;
    delegate.callbackId = command.callbackId;
    delegate.objectId = objectId;
    delegate.source = source;
	delegate.paused = false;
	delegate.business = @"download";
    delegate.offset = offset;
    delegate.total = total;
    delegate.target = [targetURL absoluteString];
    delegate.targetName = target;
    delegate.targetURL = targetURL; //下载到临时文件
    delegate.trustAllHosts = trustAllHosts;
    delegate.filePlugin = [self.commandDelegate getCommandInstance:@"File"];
    delegate.backgroundTaskID = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
        NSLog(@"Download finished.......");
        [delegate cancelTransfer:delegate.connection];
    }];
    
    NSLog(@"即将下载文件:%@", delegate.target);

    delegate.connection = [[NSURLConnection alloc] initWithRequest:req delegate:delegate startImmediately:NO];

    if (self.queue == nil) {
        self.queue = [[NSOperationQueue alloc] init];
    }
    [delegate.connection setDelegateQueue:self.queue];

    @synchronized (activeTransfers) {
        activeTransfers[delegate.objectId] = delegate;
    }
    // Downloads can take time
    // sending this to a new thread calling the download_async method
    dispatch_async(
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, (unsigned long)NULL),
                   ^(void) { [delegate.connection start];}
                   );
}

- (NSMutableDictionary*)createFileTransferError:(int)code AndSource:(NSString*)source AndTarget:(NSString*)target
{
    NSMutableDictionary* result = [NSMutableDictionary dictionaryWithCapacity:3];

    [result setObject:[NSNumber numberWithInt:code] forKey:@"code"];
    if (source != nil) {
        [result setObject:source forKey:@"source"];
    }
    if (target != nil) {
        [result setObject:target forKey:@"target"];
    }
    NSLog(@"FileTransferError %@", result);

    return result;
}

- (NSMutableDictionary*)createFileTransferError:(int)code
                                      AndSource:(NSString*)source
                                      AndTarget:(NSString*)target
                                  AndHttpStatus:(int)httpStatus
                                        AndBody:(NSString*)body
{
    NSMutableDictionary* result = [NSMutableDictionary dictionaryWithCapacity:5];

    [result setObject:[NSNumber numberWithInt:code] forKey:@"code"];
    if (source != nil) {
        [result setObject:source forKey:@"source"];
    }
    if (target != nil) {
        [result setObject:target forKey:@"target"];
    }
    [result setObject:[NSNumber numberWithInt:httpStatus] forKey:@"http_status"];
    if (body != nil) {
        [result setObject:body forKey:@"body"];
    }
    NSLog(@"FileTransferError %@", result);

    return result;
}

- (void)onReset {
    @synchronized (activeTransfers) {
        while ([activeTransfers count] > 0) {
            CDVFileTransferDelegate* delegate = [activeTransfers allValues][0];
            [delegate cancelTransfer:delegate.connection];
        }
    }
}

@end

@interface CDVFileTransferEntityLengthRequest : NSObject {
    NSURLConnection* _connection;
    CDVFileTransferDelegate* __weak _originalDelegate;
}

- (CDVFileTransferEntityLengthRequest*)initWithOriginalRequest:(NSURLRequest*)originalRequest andDelegate:(CDVFileTransferDelegate*)originalDelegate;

@end

@implementation CDVFileTransferEntityLengthRequest

- (CDVFileTransferEntityLengthRequest*)initWithOriginalRequest:(NSURLRequest*)originalRequest andDelegate:(CDVFileTransferDelegate*)originalDelegate
{
    if (self) {
        DLog(@"Requesting entity length for GZIPped content...");

        NSMutableURLRequest* req = [originalRequest mutableCopy];
        [req setHTTPMethod:@"HEAD"];
        [req setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];

        _originalDelegate = originalDelegate;
        _connection = [NSURLConnection connectionWithRequest:req delegate:self];
    }
    return self;
}

- (void)connection:(NSURLConnection*)connection didReceiveResponse:(NSURLResponse*)response
{
    DLog(@"HEAD request returned; content-length is %lld", [response expectedContentLength]);
    [_originalDelegate updateBytesExpected:[response expectedContentLength]];
}

- (void)connection:(NSURLConnection*)connection didReceiveData:(NSData*)data
{}

- (void)connectionDidFinishLoading:(NSURLConnection*)connection
{}

@end

@implementation CDVFileTransferDelegate

@synthesize callbackId, connection = _connection, source, target, responseData, responseHeaders, command, bytesTransfered, bytesExpected, direction, responseCode, objectId, targetFileHandle, filePlugin;

- (void)connectionDidFinishLoading:(NSURLConnection*)connection
{
    NSString* uploadResponse = nil;
    NSString* downloadResponse = nil;
    NSMutableDictionary* uploadResult;
    CDVPluginResult* result = nil;

    if (self.direction == CDV_TRANSFER_UPLOAD) {
        NSLog(@"Upload finished...");
        uploadResponse = [[NSString alloc] initWithData:self.responseData encoding:NSUTF8StringEncoding];
        if (uploadResponse == nil) {
            uploadResponse = [[NSString alloc] initWithData: self.responseData encoding:NSISOLatin1StringEncoding];
        }

        if ((self.responseCode >= 200) && (self.responseCode < 300)) {
            // create dictionary to return FileUploadResult object
            uploadResult = [NSMutableDictionary dictionaryWithCapacity:3];
            if (uploadResponse != nil) {
                [uploadResult setObject:uploadResponse forKey:@"response"];
                [uploadResult setObject:self.responseHeaders forKey:@"headers"];
            }
            [uploadResult setObject:[NSNumber numberWithLongLong:(self.bytesTransfered + self.offset)] forKey:@"bytesSent"];
            [uploadResult setObject:[NSNumber numberWithInt:self.responseCode] forKey:@"responseCode"];
            result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:uploadResult];
        } else {
            result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:[command createFileTransferError:CONNECTION_ERR AndSource:source AndTarget:target AndHttpStatus:self.responseCode AndBody:uploadResponse]];
        }
        [self.command.commandDelegate sendPluginResult:result callbackId:callbackId];
    }
    if (self.direction == CDV_TRANSFER_DOWNLOAD) {
        if (self.targetFileHandle) {
            [self.targetFileHandle closeFile];
            self.targetFileHandle = nil;
            DLog(@"File Transfer Download success");
            
            NSFileManager *fileManager = [NSFileManager defaultManager];

            //检查文件是否存在
            NSString* name = [self.targetName stringByReplacingOccurrencesOfString:@"file://"
                                                                              withString:@""];
            NSString* currentName = [[self targetFilePath] stringByReplacingOccurrencesOfString:@"file://"
                                                                                     withString:@""];
            //如果文件存在，则先删除
            NSError *error = nil;
            BOOL flag = [fileManager moveItemAtPath:currentName toPath:name error:&error];
            if(flag) {
                NSLog(@"文件重命名成功...%@,%@", [self targetFilePath], name);
            } else {
                NSLog(@"文件已存在，先删除后重命名, %@, %@", self.target, name);
                [fileManager removeItemAtPath:name error:nil];
                [fileManager moveItemAtPath:currentName toPath:name error:&error];
            }
            [self setProgress:false];
        } else {
            downloadResponse = [[NSString alloc] initWithData:self.responseData encoding:NSUTF8StringEncoding];
            if (downloadResponse == nil) {
                downloadResponse = [[NSString alloc] initWithData: self.responseData encoding:NSISOLatin1StringEncoding];
            }

            CDVFileTransferError errorCode = self.responseCode == 404 ? FILE_NOT_FOUND_ERR
                : (self.responseCode == 304 ? NOT_MODIFIED : CONNECTION_ERR);
            result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:[command createFileTransferError:errorCode AndSource:source AndTarget:target AndHttpStatus:self.responseCode AndBody:downloadResponse]];
            [self.command.commandDelegate sendPluginResult:result callbackId:callbackId];
        }
    }


    // remove connection for activeTransfers
    @synchronized (command.activeTransfers) {
        [command.activeTransfers removeObjectForKey:objectId];
        // remove background id task in case our upload was done in the background
        [[UIApplication sharedApplication] endBackgroundTask:self.backgroundTaskID];
        self.backgroundTaskID = UIBackgroundTaskInvalid;
    }
}

- (void)removeTargetFile
{
    NSFileManager* fileMgr = [NSFileManager defaultManager];

    NSString *targetPath = [self targetFilePath];
    if ([fileMgr fileExistsAtPath:targetPath])
    {
        [fileMgr removeItemAtPath:targetPath error:nil];
    }
}

- (void)cancelTransferOnPause:(NSURLConnection*)connection
{
    [connection cancel];
    @synchronized (self.command.activeTransfers) {
        CDVFileTransferDelegate* delegate = self.command.activeTransfers[self.objectId];
        [self.command.activeTransfers removeObjectForKey:self.objectId];
        [[UIApplication sharedApplication] endBackgroundTask:delegate.backgroundTaskID];
        delegate.backgroundTaskID = UIBackgroundTaskInvalid;
    }
    
    //暂停下载，需对文件重命名
    if (self.direction == CDV_TRANSFER_DOWNLOAD) {
        //获取文件总大小
        NSFileManager *fileManager = [NSFileManager defaultManager];
        long long loaded = self.bytesTransfered + self.offset;
        NSString* target = [[self targetFilePath] stringByReplacingOccurrencesOfString:@"file://"
                                                                            withString:@""];
        NSLog(@"查询文件：%@, 预测大小：%lld", target, loaded);
        if ([fileManager fileExistsAtPath:target]){
            loaded = [[fileManager attributesOfItemAtPath:target error:nil] fileSize];
            NSLog(@"文件暂停时已下载%lld,记录大小%lld, 总大小%lld", loaded, self.bytesTransfered, self.bytesExpected);
            if(loaded != self.bytesTransfered + self.offset) {
//                self.bytesTransfered = loaded;
                NSLog(@"警告：文件进度大小已被重置.......");
            }
        }
        //检查文件是否存在
        NSString* name = [self targetName];
        if(loaded < self.bytesExpected) {
            //文件尚未下载完毕
            name = [NSString stringWithFormat:@"%@%@%lld%@%lld%@", self.targetName, @".[Range==bytes=0-", loaded - 1, @"=Total==", self.bytesExpected, @"].downloading"];
        }
        name = [name stringByReplacingOccurrencesOfString:@"file://" withString:@""];
        NSLog(@"重命名到文件：%@", name);
        NSString* currentName = [[self targetFilePath] stringByReplacingOccurrencesOfString:@"file://" withString:@""];
        //如果文件存在，则先删除
        NSError *error = nil;
        BOOL flag = [fileManager moveItemAtPath:currentName toPath:name error:&error];
        if(flag) {
            NSLog(@"文件重命名成功...");
        } else {
            NSLog(@"文件已存在，先删除后重命名");
            [fileManager removeItemAtPath:name error:nil];
            [fileManager moveItemAtPath:currentName toPath:name error:&error];
        }
    }
}

- (void)cancelTransfer:(NSURLConnection*)connection
{
    [connection cancel];
    @synchronized (self.command.activeTransfers) {
        CDVFileTransferDelegate* delegate = self.command.activeTransfers[self.objectId];
        [self.command.activeTransfers removeObjectForKey:self.objectId];
        [[UIApplication sharedApplication] endBackgroundTask:delegate.backgroundTaskID];
        delegate.backgroundTaskID = UIBackgroundTaskInvalid;
    }

    if (self.direction == CDV_TRANSFER_DOWNLOAD) {
        [self removeTargetFile];
    }
}

- (void)cancelTransferWithError:(NSURLConnection*)connection errorMessage:(NSString*)errorMessage
{
    CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_IO_EXCEPTION messageAsDictionary:[self.command createFileTransferError:FILE_NOT_FOUND_ERR AndSource:self.source AndTarget:self.target AndHttpStatus:self.responseCode AndBody:errorMessage]];

    NSLog(@"File Transfer Error: %@", errorMessage);
    [self cancelTransfer:connection];
    [self.command.commandDelegate sendPluginResult:result callbackId:callbackId];
}

- (NSString *)targetFilePath
{
    NSString *path = nil;
    CDVFilesystemURL *sourceURL = [CDVFilesystemURL fileSystemURLWithString:self.target];
    if (sourceURL && sourceURL.fileSystemName != nil) {
        // This requires talking to the current CDVFile plugin
        NSObject<CDVFileSystem> *fs = [self.filePlugin filesystemForURL:sourceURL];
        path = [fs filesystemPathForURL:sourceURL];
    } else {
        // Extract the path part out of a file: URL.
        path = [self.target hasPrefix:@"/"] ? [self.target copy] : [(NSURL *)[NSURL URLWithString:self.target] path];
    }
    return path;
}

- (void)connection:(NSURLConnection*)connection didReceiveResponse:(NSURLResponse*)response
{
    NSError* __autoreleasing error = nil;

    self.mimeType = [response MIMEType];
    self.targetFileHandle = nil;

    // required for iOS 4.3, for some reason; response is
    // a plain NSURLResponse, not the HTTP subclass
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse* httpResponse = (NSHTTPURLResponse*)response;

        self.responseCode = (int)[httpResponse statusCode];
        self.bytesExpected = [response expectedContentLength] + self.offset;
        self.responseHeaders = [httpResponse allHeaderFields];
        if ((self.direction == CDV_TRANSFER_DOWNLOAD) && (self.responseCode == 200) && (self.bytesExpected == NSURLResponseUnknownLength)) {
            // Kick off HEAD request to server to get real length
            // bytesExpected will be updated when that response is returned
            self.entityLengthRequest = [[CDVFileTransferEntityLengthRequest alloc] initWithOriginalRequest:connection.currentRequest andDelegate:self];
        }
    } else if ([response.URL isFileURL]) {
        NSDictionary* attr = [[NSFileManager defaultManager] attributesOfItemAtPath:[response.URL path] error:nil];
        self.responseCode = 200;
        self.bytesExpected = [attr[NSFileSize] longLongValue] + self.offset;
    } else {
        self.responseCode = 200;
        self.bytesExpected = NSURLResponseUnknownLength;
    }
    if ((self.direction == CDV_TRANSFER_DOWNLOAD) && (self.responseCode >= 200) && (self.responseCode < 300)) {
        // Download response is okay; begin streaming output to file
        NSString *filePath = [self targetFilePath];
        if (filePath == nil) {
            // We couldn't find the asset.  Send the appropriate error.
            [self cancelTransferWithError:connection errorMessage:[NSString stringWithFormat:@"Could not create target file"]];
            return;
        }

        NSString* parentPath = [filePath stringByDeletingLastPathComponent];

        // create parent directories if needed
        if ([[NSFileManager defaultManager] createDirectoryAtPath:parentPath withIntermediateDirectories:YES attributes:nil error:&error] == NO) {
            if (error) {
                [self cancelTransferWithError:connection errorMessage:[NSString stringWithFormat:@"Could not create path to save downloaded file: %@", [error localizedDescription]]];
            } else {
                [self cancelTransferWithError:connection errorMessage:@"Could not create path to save downloaded file"];
            }
            return;
        }
        
        // open target file for writing
        self.targetFileHandle = [NSFileHandle fileHandleForUpdatingAtPath:filePath];
        if (self.targetFileHandle == nil) {
            // create target file
            if ([[NSFileManager defaultManager] createFileAtPath:filePath contents:nil attributes:nil] == NO) {
                [self cancelTransferWithError:connection errorMessage:@"Could not create target file"];
                return;
            }
            self.targetFileHandle = [NSFileHandle fileHandleForWritingAtPath:filePath];
        } else {
            long long offset = [self.targetFileHandle seekToEndOfFile];
            if(offset != self.offset) {
                NSLog(@"FIle offset %lld is not equal to self.offset %lld", offset, self.offset);
                self.offset = offset;
            }
        }

//        if (self.targetFileHandle == nil) {
//            [self cancelTransferWithError:connection errorMessage:@"Could not open target file for writing"];
//            // create target file
//            if ([[NSFileManager defaultManager] createFileAtPath:filePath contents:nil attributes:nil] == NO) {
//                [self cancelTransferWithError:connection errorMessage:@"Could not create target file"];
//                return;
//            }
//            self.targetFileHandle = [NSFileHandle fileHandleForWritingAtPath:filePath];
//        }
        DLog(@"Streaming to file %@", filePath);
    } else if(self.direction == CDV_TRANSFER_DOWNLOAD) {
        [self cancelTransferWithError:connection errorMessage:[NSString stringWithFormat:@"File not exists"]];
    }
}

- (void)connection:(NSURLConnection*)connection didFailWithError:(NSError*)error
{
    NSString* body = [[NSString alloc] initWithData:self.responseData encoding:NSUTF8StringEncoding];
    CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:[command createFileTransferError:CONNECTION_ERR AndSource:source AndTarget:target AndHttpStatus:self.responseCode AndBody:body]];

    NSLog(@"File Transfer Error: %@", [error localizedDescription]);

    [self cancelTransfer:connection];
    [self.command.commandDelegate sendPluginResult:result callbackId:callbackId];
}

- (void)connection:(NSURLConnection*)connection didReceiveData:(NSData*)data
{
    self.bytesTransfered += data.length;
    if (self.targetFileHandle) {
        [self.targetFileHandle writeData:data];
    } else {
        [self.responseData appendData:data];
    }
    [self updateProgress];
}

- (void)updateBytesExpected:(long long)newBytesExpected
{
    DLog(@"Updating bytesExpected to %lld", newBytesExpected);
    self.bytesExpected = newBytesExpected + self.offset;
    [self updateProgress];
}

- (void)setProgress:(BOOL)lengthComputable
{
    NSMutableDictionary* downloadProgress = [NSMutableDictionary dictionaryWithCapacity:3];
    [downloadProgress setObject:[NSNumber numberWithBool:lengthComputable] forKey:@"lengthComputable"];
    [downloadProgress setObject:[NSNumber numberWithLongLong:(self.bytesTransfered + self.offset)] forKey:@"loaded"];
    [downloadProgress setObject:[NSNumber numberWithLongLong:self.bytesExpected] forKey:@"total"];
    //NSLog(@"Update progress:%lld,%lld", (self.bytesTransfered + self.offset), (long)self.bytesExpected);
    CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:downloadProgress];
    [result setKeepCallbackAsBool:true];
    [self.command.commandDelegate sendPluginResult:result callbackId:callbackId];
}

- (void)updateProgress
{
    if (self.direction == CDV_TRANSFER_DOWNLOAD) {
        BOOL lengthComputable = (self.bytesExpected != NSURLResponseUnknownLength);
        // If the response is GZipped, and we have an outstanding HEAD request to get
        // the length, then hold off on sending progress events.
        if (!lengthComputable && (self.entityLengthRequest != nil)) {
            return;
        }
        [self setProgress:lengthComputable];
    }
}

- (void)connection:(NSURLConnection*)connection didSendBodyData:(NSInteger)bytesWritten totalBytesWritten:(NSInteger)totalBytesWritten totalBytesExpectedToWrite:(NSInteger)totalBytesExpectedToWrite
{
//    if(self.paused) {
//        NSLog(@"用户已停止上传, connection中止.......");
//        return;
//    }
    if (self.direction == CDV_TRANSFER_UPLOAD) {
        NSMutableDictionary* uploadProgress = [NSMutableDictionary dictionaryWithCapacity:3];

        [uploadProgress setObject:[NSNumber numberWithBool:true] forKey:@"lengthComputable"];
        [uploadProgress setObject:[NSNumber numberWithLongLong:(totalBytesWritten + self.offset)] forKey:@"loaded"];
        [uploadProgress setObject:[NSNumber numberWithLongLong:(totalBytesExpectedToWrite + self.offset)] forKey:@"total"];
        //NSLog(@"Uploaded: %ld, total: %ld", (long)totalBytesWritten, (long)totalBytesExpectedToWrite);
        CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:uploadProgress];
        [result setKeepCallbackAsBool:true];
        [self.command.commandDelegate sendPluginResult:result callbackId:callbackId];
    }
    self.bytesTransfered = totalBytesWritten;
}

// for self signed certificates
- (void)connection:(NSURLConnection*)connection willSendRequestForAuthenticationChallenge:(NSURLAuthenticationChallenge*)challenge
{
    if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
        if (self.trustAllHosts) {
            NSURLCredential* credential = [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust];
            [challenge.sender useCredential:credential forAuthenticationChallenge:challenge];
        }
        [challenge.sender continueWithoutCredentialForAuthenticationChallenge:challenge];
    } else {
        [challenge.sender performDefaultHandlingForAuthenticationChallenge:challenge];
    }
}

- (id)init
{
    if ((self = [super init])) {
        self.responseData = [NSMutableData data];
        self.targetFileHandle = nil;
    }
    return self;
}

@end
