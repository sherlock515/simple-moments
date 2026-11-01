#import <Foundation/Foundation.h>
#import <ImageCaptureCore/ImageCaptureCore.h>

@interface PhotoReader : NSObject <ICDeviceBrowserDelegate, ICCameraDeviceDelegate, ICCameraDeviceDownloadDelegate>
@property(strong) ICDeviceBrowser *browser;
@property(strong) NSMutableArray<ICCameraDevice *> *devices;
@property(strong) ICCameraDevice *camera;
@property(strong) NSMutableArray<ICCameraFile *> *queue;
@property(strong) NSMutableArray<NSMutableDictionary *> *rows;
@property(strong) NSMutableArray *undated;
@property(strong) NSString *output;
@property(strong) NSString *requestedDate;
@property(strong) NSDate *start;
@property(strong) NSDate *end;
@property(strong) NSDateFormatter *formatter;
@property(strong) NSString *failure;
@property NSUInteger position;
@property BOOL done;
@property BOOL catalogRead;
- (void)saveManifest;
- (void)nextFile;
@end

@implementation PhotoReader
- (void)deviceBrowser:(ICDeviceBrowser *)b didAddDevice:(ICDevice *)d moreComing:(BOOL)m {
    if ([d isKindOfClass:ICCameraDevice.class] && ![self.devices containsObject:(ICCameraDevice *)d])
        [self.devices addObject:(ICCameraDevice *)d];
}
- (void)deviceBrowser:(ICDeviceBrowser *)b didRemoveDevice:(ICDevice *)d moreGoing:(BOOL)m {
    [self.devices removeObject:(ICCameraDevice *)d];
    if (d == self.camera) { self.failure=@"Device disconnected"; self.done=YES; }
}
- (void)device:(ICDevice *)d didOpenSessionWithError:(NSError *)e {
    if (e) { self.failure=e.localizedDescription; self.done=YES; }
}
- (void)device:(ICDevice *)d didCloseSessionWithError:(NSError *)e {}
- (void)didRemoveDevice:(ICDevice *)d { self.failure=@"Device disconnected"; self.done=YES; }
- (void)cameraDevice:(ICCameraDevice *)c didAddItems:(NSArray *)a {}
- (void)cameraDevice:(ICCameraDevice *)c didRemoveItems:(NSArray *)a {}
- (void)cameraDevice:(ICCameraDevice *)c didReceiveThumbnail:(CGImageRef)t forItem:(ICCameraItem *)i error:(NSError *)e {}
- (void)cameraDevice:(ICCameraDevice *)c didReceiveMetadata:(NSDictionary *)m forItem:(ICCameraItem *)i error:(NSError *)e {}
- (void)cameraDevice:(ICCameraDevice *)c didRenameItems:(NSArray *)a {}
- (void)cameraDeviceDidChangeCapability:(ICCameraDevice *)c {}
- (void)cameraDevice:(ICCameraDevice *)c didReceivePTPEvent:(NSData *)d {}
- (void)cameraDeviceDidRemoveAccessRestriction:(ICDevice *)d {}
- (void)cameraDeviceDidEnableAccessRestriction:(ICDevice *)d {}
- (BOOL)cameraDevice:(ICCameraDevice *)c shouldGetThumbnailOfItem:(ICCameraItem *)i { return NO; }
- (BOOL)cameraDevice:(ICCameraDevice *)c shouldGetMetadataOfItem:(ICCameraItem *)i { return NO; }
- (NSString *)relativePath:(ICCameraItem *)item {
    NSMutableArray *parts=[NSMutableArray new];
    for (ICCameraItem *p=item; p; p=p.parentFolder) [parts insertObject:p.name ?: @"unnamed" atIndex:0];
    return [NSString pathWithComponents:parts];
}
- (void)saveManifest {
    NSDictionary *manifest=@{@"requested_date":self.requestedDate,
        @"timezone":self.formatter.timeZone.name, @"device":self.camera.name ?: @"",
        @"date_basis":@"ImageCaptureCore creationDate; EXIF verification required",
        @"candidate_window":@"target date plus adjacent days",
        @"undated_images":self.undated ?: @[], @"files":self.rows ?: @[],
        @"error":self.failure ?: @"", @"complete":@(self.done && !self.failure)};
    NSError *e=nil;
    NSData *data=[NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingPrettyPrinted error:&e];
    if (!data || ![data writeToFile:[self.output stringByAppendingPathComponent:@"import-manifest.json"] options:NSDataWritingAtomic error:&e]) {
        self.failure=e.localizedDescription ?: @"Manifest write failed";
        self.done=YES;
    }
}
- (void)deviceDidBecomeReadyWithCompleteContentCatalog:(ICCameraDevice *)c {
    if (self.catalogRead) return;
    self.catalogRead=YES;
    NSSet *images=[NSSet setWithArray:@[@"jpg",@"jpeg",@"heic",@"heif",@"png",@"dng",@"tif",@"tiff",@"webp",@"avif",@"gif",@"cr2",@"cr3",@"nef",@"arw",@"raf",@"rw2",@"orf"]];
    NSMutableSet *stems=[NSMutableSet new];
    self.queue=[NSMutableArray new]; self.rows=[NSMutableArray new]; self.undated=[NSMutableArray new];
    for (ICCameraItem *i in c.mediaFiles) {
        if (![i isKindOfClass:ICCameraFile.class] || ![images containsObject:i.name.pathExtension.lowercaseString]) continue;
        if (!i.creationDate) { [self.undated addObject:[self relativePath:i]]; continue; }
        if ([i.creationDate compare:self.start] != NSOrderedAscending && [i.creationDate compare:self.end] == NSOrderedAscending) {
            [self.queue addObject:(ICCameraFile *)i];
            [stems addObject:[self relativePath:i].stringByDeletingPathExtension];
        }
    }
    for (ICCameraItem *i in c.mediaFiles) {
        if (![i isKindOfClass:ICCameraFile.class]) continue;
        if ([@[@"mov",@"mp4"] containsObject:i.name.pathExtension.lowercaseString] &&
            [stems containsObject:[self relativePath:i].stringByDeletingPathExtension]) [self.queue addObject:(ICCameraFile *)i];
    }
    [self.queue sortUsingComparator:^NSComparisonResult(ICCameraFile *a, ICCameraFile *b) {
        return [[self relativePath:a] compare:[self relativePath:b]];
    }];
    for (ICCameraFile *f in self.queue) {
        [self.rows addObject:[@{@"source_name":f.name ?: @"", @"source_path":[self relativePath:f],
            @"device_date":f.creationDate ? [self.formatter stringFromDate:f.creationDate] : @"",
            @"source_bytes":@(f.fileSize), @"status":@"pending"} mutableCopy]];
    }
    fprintf(stderr,"Found %lu candidate files (including adjacent dates); EXIF verification follows.\n",(unsigned long)self.queue.count);
    [self saveManifest];
    if (!self.done) [self nextFile];
}
- (void)nextFile {
    if (self.done) return;
    if (self.position >= self.queue.count) { self.done=YES; [self saveManifest]; return; }
    NSString *folder=[self.output stringByAppendingPathComponent:[NSString stringWithFormat:@"%06lu",(unsigned long)self.position+1]];
    NSError *e=nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:NO attributes:nil error:&e]) {
        self.failure=e.localizedDescription; self.done=YES; [self saveManifest]; return;
    }
    ICCameraFile *f=self.queue[self.position];
    self.rows[self.position][@"directory"]=folder;
    NSString *name=f.name.lastPathComponent;
    if (!name.length || [name isEqualToString:@"."] || [name isEqualToString:@".."]) name=@"unnamed";
    NSDictionary *options=@{ICDownloadsDirectoryURL:[NSURL fileURLWithPath:folder isDirectory:YES],
        ICSaveAsFilename:name, ICOverwrite:@NO, ICDeleteAfterSuccessfulDownload:@NO};
    [self.camera requestDownloadFile:f options:options downloadDelegate:self
        didDownloadSelector:@selector(didDownloadFile:error:options:contextInfo:) contextInfo:NULL];
}
- (void)didDownloadFile:(ICCameraFile *)f error:(NSError *)e options:(NSDictionary *)options contextInfo:(void *)context {
    if (self.done) return;
    NSMutableDictionary *row=self.rows[self.position];
    NSString *folder=row[@"directory"];
    NSArray *files=[[NSFileManager defaultManager] contentsOfDirectoryAtPath:folder error:nil];
    NSString *name=options[ICSavedFilename];
    if (!name && files.count==1) name=files.firstObject;
    NSString *path=name ? [folder stringByAppendingPathComponent:name.lastPathComponent] : nil;
    NSDictionary *attrs=path ? [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil] : nil;
    BOOL valid=!e && attrs && [attrs fileSize]>0 && (f.fileSize==0 || [attrs fileSize]==f.fileSize);
    row[@"status"]=valid ? @"downloaded" : @"failed";
    if (path) row[@"local_path"]=path;
    if (attrs) row[@"local_bytes"]=@([attrs fileSize]);
    if (!valid) {
        row[@"error"]=e.localizedDescription ?: @"Downloaded file missing, empty or size differs from device";
        self.failure=@"One or more files failed; inspect manifest";
    }
    self.position++;
    [self saveManifest];
    [self nextFile];
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc==2 && strcmp(argv[1],"--help")==0) {
            puts("Usage: usb-photos YYYY-MM-DD TIMEZONE NEW_OUTPUT_DIRECTORY [EXACT_DEVICE_NAME]\nDownloads image candidates from the date and adjacent days plus paired videos. Never deletes device files."); return 0;
        }
        if (argc<4 || argc>5) { fprintf(stderr,"Use --help for usage.\n"); return 2; }
        PhotoReader *r=[PhotoReader new];
        r.requestedDate=@(argv[1]);
        NSTimeZone *tz=[NSTimeZone timeZoneWithName:@(argv[2])];
        NSDateFormatter *df=[NSDateFormatter new];
        df.locale=[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        df.calendar=[[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
        df.timeZone=tz; df.dateFormat=@"yyyy-MM-dd"; df.lenient=NO;
        NSDate *day=[df dateFromString:r.requestedDate];
        if (!tz || !day || ![[df stringFromDate:day] isEqualToString:r.requestedDate]) { fprintf(stderr,"Invalid date or timezone.\n"); return 2; }
        NSCalendar *calendar=df.calendar; calendar.timeZone=tz;
        r.start=[calendar dateByAddingUnit:NSCalendarUnitDay value:-1 toDate:day options:0];
        r.end=[calendar dateByAddingUnit:NSCalendarUnitDay value:2 toDate:day options:0];
        df.dateFormat=@"yyyy-MM-dd'T'HH:mm:ssZZZZZ"; r.formatter=df;
        r.output=[@(argv[3]) stringByStandardizingPath];
        if (![r.output isAbsolutePath]) r.output=[NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:r.output];
        NSError *e=nil;
        if ([NSFileManager.defaultManager fileExistsAtPath:r.output] ||
            ![NSFileManager.defaultManager createDirectoryAtPath:r.output withIntermediateDirectories:NO attributes:nil error:&e]) {
            fprintf(stderr,"Output must be a new directory with an existing parent: %s\n",e.localizedDescription.UTF8String ?: "already exists"); return 2;
        }
        r.devices=[NSMutableArray new]; r.browser=[ICDeviceBrowser new]; r.browser.delegate=r;
        [r.browser start];
        NSDate *scanLimit=[NSDate dateWithTimeIntervalSinceNow:5];
        while ([scanLimit timeIntervalSinceNow]>0) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        NSMutableArray *matches=[NSMutableArray new];
        for (ICCameraDevice *d in r.devices) {
            if (argc==4 || [d.name isEqualToString:@(argv[4])]) [matches addObject:d];
        }
        if (matches.count!=1) {
            r.failure=matches.count ? @"Multiple devices; specify exact device name" : @"No matching readable camera device detected";
            fprintf(stderr,"%s\n",r.failure.UTF8String);
            for (ICCameraDevice *d in r.devices) fprintf(stderr,"Device: %s\n",d.name.UTF8String);
            r.done=YES; [r saveManifest]; [r.browser stop]; return 3;
        }
        r.camera=matches.firstObject; r.camera.delegate=r; [r.camera requestOpenSession];
        NSDate *limit=[NSDate dateWithTimeIntervalSinceNow:300];
        while (!r.done && [limit timeIntervalSinceNow]>0) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        if (!r.done) { r.failure=@"Timed out; inspect manifest for completed downloads"; r.done=YES; }
        [r saveManifest];
        if (r.camera.hasOpenSession) [r.camera requestCloseSession];
        [r.browser stop];
        if (r.failure) fprintf(stderr,"%s\n",r.failure.UTF8String);
        else fprintf(stderr,"Downloaded %lu candidate files.\n",(unsigned long)r.position);
        return r.failure ? 4 : 0;
    }
}
