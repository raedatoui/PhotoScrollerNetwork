/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * *
 *
 * This file is part of PhotoScrollerNetwork -- An iOS project that smoothly and efficiently
 * renders large images in progressively smaller ones for display in a CATiledLayer backed view.
 * Images can either be local, or more interestingly, downloaded from the internet.
 * Images can be rendered by an iOS CGImageSource, libjpeg-turbo, or incrmentally by
 * libjpeg (the turbo version) - the latter gives the best speed.
 *
 * Parts taken with minor changes from Apple's PhotoScroller sample code, the
 * ConcurrentOp from my ConcurrentOperations github sample code, and TiledImageBuilder
 * was completely original source code developed by me.
 *
 * Copyright 2012 David Hoerl All Rights Reserved.
 *
 *
 * Redistribution and use in source and binary forms, with or without modification, are
 * permitted provided that the following conditions are met:
 *
 *    1. Redistributions of source code must retain the above copyright notice, this list of
 *       conditions and the following disclaimer.
 *
 *    2. Redistributions in binary form must reproduce the above copyright notice, this list
 *       of conditions and the following disclaimer in the documentation and/or other materials
 *       provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY David Hoerl ''AS IS'' AND ANY EXPRESS OR IMPLIED
 * WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND
 * FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL David Hoerl OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
 * ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
 * NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
 * ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

#define MEMORY_DEBUGGING	1		// set to 1 if you want to see how memory changes when images are processed (non Turbo)
#define MMAP_DEBUGGING		0		// set to 1 to see how mmap/munmap working
#define USE_VIMAGE			0		// set to 1 if you want vImage to downsize images (slightly better quality, much much slower)

#include <libkern/OSAtomic.h>

#include <mach/mach.h>			// freeMemory
#include <mach/mach_host.h>		// freeMemory
#include <mach/mach_time.h>		// time metrics
#include <mach/task_info.h>		// task metrics

#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/sysctl.h>
#include <sys/stat.h>


#if USE_VIMAGE == 1
#import <Accelerate/Accelerate.h>
#endif

#ifdef LIBJPEG	
#include "jpeglib.h"
#include "turbojpeg.h"
#include <setjmp.h>
#endif

#import <ImageIO/ImageIO.h>
#import <MobileCoreServices/MobileCoreServices.h> // kUTTypePNG

#import "TiledImageBuilder.h"

static const size_t bytesPerPixel = 4;
static const size_t bitsPerComponent = 8;
static const size_t tileDimension = TILE_SIZE;
static const size_t tileBytesPerRow = tileDimension * bytesPerPixel;
static const size_t tileSize = tileBytesPerRow * tileDimension;

static inline long		offsetFromScale(CGFloat scale) { long s = lrintf(scale*1000.f); long idx = 0; while(s < 1000) s *= 2, ++idx; return idx; }
static inline size_t	calcDimension(size_t d) { return(d + (tileDimension-1)) & ~(tileDimension-1); }
static inline size_t	calcBytesPerRow(size_t row) { return calcDimension(row) * bytesPerPixel; }

static size_t PhotoScrollerProviderGetBytesAtPosition (
    void *info,
    void *buffer,
    off_t position,
    size_t count
);
static void PhotoScrollerProviderReleaseInfoCallback (
    void *info
);

typedef struct {
	int fd;
	unsigned char *addr;		// address == emptyAddr + emptyTileRowSize
	unsigned char *emptyAddr;	// first address of allocated space
	size_t mappedSize;			// all space from emptyAddr to end of file
	size_t height;				// image
	size_t width;				// image
	size_t bytesPerRow;			// image
	size_t emptyTileRowSize;	// free space at the beginning of the file
} mapper;

typedef struct {
	size_t freeMemory;
	size_t usedMemory;
	size_t totlMemory;
	size_t resident_size;
	size_t virtual_size;
} freeMemory;

static freeMemory freeMem(NSString *msg);
static BOOL dump_memory_usage(struct task_basic_info *info);


#ifndef NDEBUG
static void dumpMapper(const char *str, mapper *m)
{
	printf("MAP: %s\n", str);
	printf(" fd = %d\n", m->fd);
	printf(" emptyAddr = %p\n", m->emptyAddr);
	printf(" addr = %p\n", m->addr);
	printf(" mappedSize = %lu\n", m->mappedSize);
	printf(" height = %lu\n", m->height);
	printf(" width = %lu\n", m->width);
	printf(" bytesPerRow = %lu\n", m->bytesPerRow);
	printf(" emptyTileRowSize = %lu\n", m->emptyTileRowSize);
	putchar('\n');
}
#endif

typedef struct {
	mapper map;

	// whole image
	size_t cols;
	size_t rows;

	// scale
	size_t index;
	
	// construction and tile prep
	size_t outLine;	
	
	// used by tiling and during construction
	size_t row;
	
	// tiling only
	size_t tileHeight;		
	size_t tileWidth;
	size_t col;

} imageMemory;

#ifndef NDEBUG
static void dumpIMS(const char *str, imageMemory *i)
{
	printf("IMS: %s\n", str);
	dumpMapper("map:", &i->map);

	printf(" idx = %ld\n", i->index);
	printf(" cols = %ld\n", i->cols);
	printf(" rows = %ld\n", i->rows);
	printf(" outline = %ld\n", i->outLine);
	printf(" col = %ld\n", i->col);
	printf(" row = %ld\n", i->row);
	putchar('\n');
}
#endif

static BOOL tileBuilder(imageMemory *im, BOOL useMMAP, BOOL fullSync);
static void truncateEmptySpace(imageMemory *im);

#ifdef LIBJPEG	

#define SCAN_LINE_MAX			1			// libjpeg docs imply you could get 4 but all I see is 1 at a time, and now the logic wants just one

static void my_error_exit(j_common_ptr cinfo);

static void init_source(j_decompress_ptr cinfo);
static boolean fill_input_buffer(j_decompress_ptr cinfo);
static void skip_input_data(j_decompress_ptr cinfo, long num_bytes);
static boolean resync_to_restart(j_decompress_ptr cinfo, int desired);
static void term_source(j_decompress_ptr cinfo);

/*
 * Here's the routine that will replace the standard error_exit method:
 */
struct my_error_mgr {
  struct jpeg_error_mgr pub;		/* "public" fields */
  jmp_buf setjmp_buffer;			/* for return to caller */
};
typedef struct my_error_mgr * my_error_ptr;

typedef struct {
	struct jpeg_source_mgr			pub;
	struct jpeg_decompress_struct	cinfo;
	struct my_error_mgr				jerr;
	
	// input data management
	unsigned char					*data;
	size_t							data_length;
	size_t							consumed_data;		// where the next chunk of data should come from, offset into the NSData object
	size_t							deleted_data;		// removed from the NSData object
	size_t							writtenLines;
	boolean							start_of_stream;
	boolean							got_header;
	boolean							jpegFailed;
} co_jpeg_source_mgr;

#endif

static CGColorSpaceRef		colorSpace;
static BOOL					only256M_memory;
static dispatch_group_t		fileFlushGroup;
static volatile	int32_t		fileFlushGroupSuspended;
static volatile int32_t		ubc_usage;					// rough idea of what our buffer cache usage is

// Compliments to Rainer Brockerhoff
static uint64_t DeltaMAT(uint64_t then, uint64_t now)
{
	uint64_t delta = now - then;

	/* Get the timebase info */
	mach_timebase_info_data_t info;
	mach_timebase_info(&info);

	/* Convert to nanoseconds */
	delta *= info.numer;
	delta /= info.denom;

	return (uint64_t)((double)delta / 1e6); // ms
}
	 
@interface TiledImageBuilder ()

#ifdef LIBJPEG
- (void)decodeImageData:(NSData *)data;
#endif

- (void)decodeImageURL:(NSURL *)url;
- (void)decodeImage:(CGImageRef)image;
- (void)drawImage:(CGImageRef)image;

- (BOOL)createImageFile;
- (int)createTempFile:(BOOL)unlinkFile size:(size_t)size;
- (void)mapMemoryForIndex:(size_t)idx width:(size_t)w height:(size_t)h;
#ifdef LIBJPEG
- (BOOL)partialTile:(BOOL)final;
#endif
- (void)run;

#ifdef LIBJPEG
- (void)jpegInitFile:(NSString *)path;
- (void)jpegInitNetwork;
- (BOOL)jpegOutputScanLines;	// return YES when done
#endif

- (uint64_t)timeStamp;
- (uint64_t)freeDiskspace;
- (freeMemory)freeMemory:(NSString *)msg;

@end

static void foo(int sig)
{
	NSLog(@"YIKES: got signal %d", sig);
	write(2, "YIKES YIKES!!!", 14);
}

@implementation TiledImageBuilder
{
	NSString *imagePath;
	FILE *imageFile;

	size_t pageSize;
	imageMemory *ims;
	imageDecoder decoder;
	BOOL mapWholeFile;
	BOOL deleteImageFile;

#ifdef LIBJPEG
	// input
	co_jpeg_source_mgr	src_mgr;
	// output
	unsigned char		*scanLines[SCAN_LINE_MAX];
#endif
}
@synthesize flushDiskCache;
@synthesize zoomLevels;
@synthesize failed;
@synthesize startTime;
@synthesize finishTime;
@synthesize milliSeconds;

+ (void)initialize
{
	if(self == [TiledImageBuilder class]) {
		colorSpace = CGColorSpaceCreateDeviceRGB();
		freeMemory fm = freeMem(@"Initialize");
		if(fm.totlMemory <= 512000000) {
			only256M_memory = YES;
		}
only256M_memory = YES;

		fileFlushGroup = dispatch_group_create();
		
		//for(int i=0; i<=31; ++i) signal(i, foo);

		size_t vms;
		size_t vmsLen = sizeof(vms);
		int ret = sysctlbyname("kern.maxvnodes", &vms, &vmsLen, NULL, 0);
		NSLog(@"sysctlbyname: vms=%d ret=%d", (int)vms*4096, ret);

		vmsLen = 0;
		ret = sysctlbyname("kern.vnode", NULL, &vmsLen, NULL, 0);
		NSLog(@"sysctlbyname: vnodes=%d ret=%d", (int)vmsLen, ret);
	}
}

- (id)initWithImage:(CGImageRef)image levels:(NSUInteger)levels
{
	if((self = [super init])) {
		startTime = [self timeStamp];

		zoomLevels = levels;
		ims = calloc(zoomLevels, sizeof(imageMemory));
		decoder = cgimageDecoder;
		pageSize = getpagesize();
		{
			mapWholeFile = YES;
			[self decodeImage:image];
		}
		finishTime = [self timeStamp];
		milliSeconds = (uint32_t)DeltaMAT(startTime, finishTime);

#ifndef NDEBUG
		NSLog(@"FINISH: %u milliseconds", milliSeconds);
#endif
	}
	return self;
}

- (id)initWithImagePath:(NSString *)path withDecode:(imageDecoder)dec levels:(NSUInteger)levels
{
	if((self = [super init])) {
		startTime = [self timeStamp];

		zoomLevels = levels;
		ims = calloc(zoomLevels, sizeof(imageMemory));
		decoder = dec;
		pageSize = getpagesize();
#ifdef LIBJPEG
		if(decoder == libjpegIncremental) {
			[self jpegInitFile:path];
		} else
#endif		
		{
			mapWholeFile = YES;
			[self decodeImageURL:[NSURL fileURLWithPath:path]];
		}
		finishTime = [self timeStamp];
		milliSeconds = (uint32_t)DeltaMAT(startTime, finishTime);

#ifndef NDEBUG
		NSLog(@"FINISH: %u milliseconds", milliSeconds);
		[self freeMemory:@"FINISHED"];
#endif
	}
	return self;
}
- (id)initForNetworkDownloadWithDecoder:(imageDecoder)dec levels:(NSUInteger)levels
{
	if((self = [super init])) {
		zoomLevels = levels;
		ims = calloc(zoomLevels, sizeof(imageMemory));
		decoder = dec;
		pageSize = getpagesize();
#ifdef LIBJPEG
		if(decoder == libjpegIncremental) {
			[self jpegInitNetwork];
		} else 
#endif
		{
			mapWholeFile = YES;
			[self createImageFile];
		}
	}
	return self;
}
- (void)dealloc
{
	for(NSUInteger idx=0; idx<zoomLevels;++idx) {
		int fd = ims[idx].map.fd;
		if(fd>0) close(fd);
	}
	free(ims);

	if(imageFile) fclose(imageFile);
	if(imagePath) unlink([imagePath fileSystemRepresentation]);
#ifdef LIBJPEG
	if(src_mgr.cinfo.src) jpeg_destroy_decompress(&src_mgr.cinfo);
#endif
}

- (uint64_t)timeStamp
{
	return mach_absolute_time();
}

- (void)appendToImageFile:(NSData *)data
{
	if(!failed) {
		size_t ret = fwrite([data bytes], [data length], 1, imageFile);
		assert(ret == [data length]);
	}
}

- (void)dataFinished
{
	if(!failed) {
		startTime = [self timeStamp];

		fclose(imageFile), imageFile = NULL;
		[self decodeImageURL:[NSURL fileURLWithPath:imagePath]];
		unlink([imagePath fileSystemRepresentation]), imagePath = NULL;
		
		finishTime = [self timeStamp];
		milliSeconds = (uint32_t)DeltaMAT(startTime, finishTime);
#ifndef NDEBUG
		NSLog(@"FINISH: %u milliseconds", milliSeconds);
		[self freeMemory:@"dataFinished"];
#endif
	}
}

#ifdef LIBJPEG
- (void)jpegInitFile:(NSString *)path
{
	const char *file = [path fileSystemRepresentation];
	int jfd = open(file, O_RDONLY, 0);
	if(jfd <= 0) {
		NSLog(@"Error: failed to open input image file \"%s\" for reading (%d).\n", file, errno);
		failed = YES;
		return;
	}
	int ret = fcntl(jfd, F_NOCACHE, 1);	// don't clog up the system's disk cache
	if(ret == -1) {
		NSLog(@"Warning: cannot turn off cacheing for input file (errno %d).", errno);
	}
	if ((imageFile = fdopen(jfd, "r")) == NULL) {
		NSLog(@"Error: failed to fdopen input image file \"%s\" for reading (%d).", file, errno);
		jpeg_destroy_decompress(&src_mgr.cinfo);
		close(jfd);
		failed = YES;
		return;
	}

	/* Step 1: allocate and initialize JPEG decompression object */

	/* We set up the normal JPEG error routines, then override error_exit. */
	src_mgr.cinfo.err = jpeg_std_error(&src_mgr.jerr.pub);
	src_mgr.jerr.pub.error_exit = my_error_exit;
	/* Establish the setjmp return context for my_error_exit to use. */
	if (setjmp(src_mgr.jerr.setjmp_buffer)) {
	/* If we get here, the JPEG code has signaled an error.
	 * We need to clean up the JPEG object, close the input file, and return.
	 */
		failed = YES;
	} else {
		/* Now we can initialize the JPEG decompression object. */
		jpeg_create_decompress(&src_mgr.cinfo);

		/* Step 2: specify data source (eg, a file) */
		jpeg_stdio_src(&src_mgr.cinfo, imageFile);

		/* Step 3: read file parameters with jpeg_read_header() */
		(void) jpeg_read_header(&src_mgr.cinfo, TRUE);

		src_mgr.cinfo.out_color_space =  JCS_EXT_ABGR;
	
		assert(src_mgr.cinfo.num_components == 3);
		assert(src_mgr.cinfo.image_width > 0 && src_mgr.cinfo.image_height > 0);
		//NSLog(@"WID=%d HEIGHT=%d", src_mgr.cinfo.image_width, src_mgr.cinfo.image_height);
		
		// Create files
		size_t scale = 1;
		for(size_t idx=0; idx<zoomLevels; ++idx) {
			[self mapMemoryForIndex:idx width:src_mgr.cinfo.image_width/scale height:src_mgr.cinfo.image_height/scale];
			if(failed) break;
			scale *= 2;
		}
		if(!failed) {
			(void)jpeg_start_decompress(&src_mgr.cinfo);
			
			while(![self jpegOutputScanLines]) ;
		}
	}
	jpeg_destroy_decompress(&src_mgr.cinfo);
	src_mgr.cinfo.src = NULL;	// dealloc tests

	fclose(imageFile), imageFile = NULL;
}

- (void)jpegInitNetwork
{
	src_mgr.pub.next_input_byte		= NULL;
	src_mgr.pub.bytes_in_buffer		= 0;
	src_mgr.pub.init_source			= init_source;
	src_mgr.pub.fill_input_buffer	= fill_input_buffer;
	src_mgr.pub.skip_input_data		= skip_input_data;
	src_mgr.pub.resync_to_restart	= resync_to_restart;
	src_mgr.pub.term_source			= term_source;
	
	src_mgr.consumed_data			= 0;
	src_mgr.start_of_stream			= TRUE;

	/* We set up the normal JPEG error routines, then override error_exit. */
	src_mgr.cinfo.err = jpeg_std_error(&src_mgr.jerr.pub);
	src_mgr.jerr.pub.error_exit = my_error_exit;
	/* Establish the setjmp return context for my_error_exit to use. */
	if (setjmp(src_mgr.jerr.setjmp_buffer)) {
		/* If we get here, the JPEG code has signaled an error.
		 * We need to clean up the JPEG object, close the input file, and return.
		 */
		//NSLog(@"YIKES! SETJUMP");
		failed = YES;
		//[self cancel];
	} else {
		/* Now we can initialize the JPEG decompression object. */
		jpeg_create_decompress(&src_mgr.cinfo);
		src_mgr.cinfo.src = &src_mgr.pub; // MUST be after the jpeg_create_decompress - ask me how I know this :-)
		//src_mgr.pub.bytes_in_buffer = 0; /* forces fill_input_buffer on first read */
		//src_mgr.pub.next_input_byte = NULL; /* until buffer loaded */
	}
}
- (void)jpegAdvance:(NSMutableData *)webData
{
	unsigned char *dataPtr = (unsigned char *)[webData mutableBytes];

	// mutable data bytes pointer can change invocation to invocation
	size_t diff					= src_mgr.pub.next_input_byte - src_mgr.data;
	src_mgr.pub.next_input_byte	= dataPtr + diff;
	src_mgr.data				= dataPtr;
	src_mgr.data_length			= [webData length];

	//NSLog(@"s1=%ld s2=%d", src_mgr.data_length, highWaterMark);
	if (setjmp(src_mgr.jerr.setjmp_buffer)) {
		/* If we get here, the JPEG code has signaled an error.
		 * We need to clean up the JPEG object, close the input file, and return.
		 */
		NSLog(@"YIKES! SETJUMP");
		failed = YES;
		return;
	}
	if(src_mgr.jpegFailed) failed = YES;

	if(!failed) {
		if(!src_mgr.got_header) {
			/* Step 3: read file parameters with jpeg_read_header() */
			int jret = jpeg_read_header(&src_mgr.cinfo, FALSE);
			if(jret == JPEG_SUSPENDED || jret != JPEG_HEADER_OK) return;
			//NSLog(@"GOT header");
			src_mgr.got_header = YES;
			src_mgr.start_of_stream = NO;
			src_mgr.cinfo.out_color_space =  JCS_EXT_ABGR;

			assert(src_mgr.cinfo.num_components == 3);
			assert(src_mgr.cinfo.image_width > 0 && src_mgr.cinfo.image_height > 0);
			//NSLog(@"WID=%d HEIGHT=%d", src_mgr.cinfo.image_width, src_mgr.cinfo.image_height);

			[self mapMemoryForIndex:0 width:src_mgr.cinfo.image_width height:src_mgr.cinfo.image_height];
			unsigned char *scratch = ims[0].map.emptyAddr;
			//NSLog(@"Scratch=%p rowBytes=%ld", scratch, rowBytes);
			for(int i=0; i<SCAN_LINE_MAX; ++i) {
				scanLines[i] = scratch;
				scratch += ims[0].map.bytesPerRow;
			}
			(void)jpeg_start_decompress(&src_mgr.cinfo);

			// Create files
			size_t scale = 1;
			for(size_t idx=0; idx<zoomLevels; ++idx) {
				[self mapMemoryForIndex:idx width:src_mgr.cinfo.image_width/scale height:src_mgr.cinfo.image_height/scale];
				scale *= 2;
			}
			if(src_mgr.jpegFailed) failed = YES;
		}
		if(src_mgr.got_header && !failed) {
			[self jpegOutputScanLines];
			
			// When we consume all the data in the web buffer, safe to free it up for the system to resuse
			if(src_mgr.pub.bytes_in_buffer == 0) {
				src_mgr.deleted_data += [webData length];
				[webData setLength:0];
			}
		}
	}
}

- (BOOL)jpegOutputScanLines
{
	if(failed) return YES;

	while(src_mgr.cinfo.output_scanline <  src_mgr.cinfo.image_height) {
		unsigned char *scanPtr;
		{
			size_t tmpMapSize = ims[0].map.bytesPerRow;
			size_t offset = src_mgr.writtenLines*ims[0].map.bytesPerRow+ims[0].map.emptyTileRowSize;
			size_t over = offset % pageSize;
			offset -= over;
			tmpMapSize += over;
			
			ims[0].map.mappedSize = tmpMapSize;
			ims[0].map.addr = mmap(NULL, ims[0].map.mappedSize, PROT_READ | PROT_WRITE, MAP_FILE | MAP_SHARED | MAP_NOCACHE, ims[0].map.fd, offset);
			if(ims[0].map.addr == MAP_FAILED) {
				NSLog(@"errno1=%s", strerror(errno) );
				failed = YES;
				ims[0].map.addr = NULL;
				ims[0].map.mappedSize = 0;
				return YES;
			}
#if MMAP_DEBUGGING == 1
			NSLog(@"MMAP[%d]: addr=%p 0x%X bytes", ims[0].map.fd, ims[0].map.addr, (NSUInteger)ims[0].map.mappedSize);
#endif
			scanPtr = ims[0].map.addr + over;
		}
	
		scanLines[0] = scanPtr;
		int lines = jpeg_read_scanlines(&src_mgr.cinfo, scanLines, SCAN_LINE_MAX);
		if(lines <= 0) {
//int mret = msync(ims[0].map.addr, ims[0].map.mappedSize, MS_ASYNC);
//assert(mret == 0);
			int ret = munmap(ims[0].map.addr, ims[0].map.mappedSize);
#if MMAP_DEBUGGING == 1
			NSLog(@"UNMAP[%d]: addr=%p 0x%X bytes", ims[0].map.fd, ims[0].map.addr, (NSUInteger)ims[0].map.mappedSize);
#endif
			assert(ret == 0);
			break;
		}
		ims[0].outLine = src_mgr.writtenLines;

		// on even numbers try to update the lower resolution scans
		if(!(src_mgr.writtenLines & 1)) {
			size_t scale = 2;
			imageMemory *im = &ims[1];
			for(size_t idx=1; idx<zoomLevels; ++idx, scale *= 2, ++im) {
				if(src_mgr.writtenLines & (scale-1)) break;

				im->outLine = src_mgr.writtenLines/scale;
				
				size_t tmpMapSize = im->map.bytesPerRow;
				size_t offset = im->outLine*tmpMapSize+im->map.emptyTileRowSize;
				size_t over = offset % pageSize;
				offset -= over;
				tmpMapSize += over;
				
				im->map.mappedSize = tmpMapSize;
				im->map.addr = mmap(NULL, im->map.mappedSize, PROT_WRITE, MAP_FILE | MAP_SHARED | MAP_NOCACHE, im->map.fd, offset); // write only 
				if(im->map.addr == MAP_FAILED) {
					NSLog(@"errno2=%s", strerror(errno) );
					failed = YES;
					im->map.addr = NULL;
					im->map.mappedSize = 0;
					return YES;
				}
#if MMAP_DEBUGGING == 1
				NSLog(@"MMAP[%d]: addr=%p 0x%X bytes", im->map.fd, im->map.addr, (NSUInteger)im->map.mappedSize);
#endif
		
				uint32_t *outPtr = (uint32_t *)(im->map.addr + over);
				uint32_t *inPtr  = (uint32_t *)scanPtr;
				
				for(size_t col=0; col<ims[0].map.width; col += scale) {
					*outPtr++ = *inPtr;
					inPtr += scale;
				}
//int mret = msync(im->map.addr, im->map.mappedSize, MS_ASYNC);
//assert(mret == 0);
				int ret = munmap(im->map.addr, im->map.mappedSize);
#if MMAP_DEBUGGING == 1
				NSLog(@"UNMAP[%d]: addr=%p 0x%X bytes", im->map.fd, im->map.addr, (NSUInteger)im->map.mappedSize);
#endif
				assert(ret == 0);
			}
		}
//int mret = msync(ims[0].map.addr, ims[0].map.mappedSize, MS_ASYNC);
//assert(mret == 0);
		int ret = munmap(ims[0].map.addr, ims[0].map.mappedSize);
#if MMAP_DEBUGGING == 1
		NSLog(@"UNMAP[%d]: addr=%p 0x%X bytes", ims[0].map.fd, ims[0].map.addr, (NSUInteger)ims[0].map.mappedSize);
#endif
		assert(ret == 0);

		// tile all images as we get full rows of tiles
		if(ims[0].outLine && !(ims[0].outLine % TILE_SIZE)) {
			failed = ![self partialTile:NO];
			if(failed) break;
		}
		src_mgr.writtenLines += lines;
	}
	//NSLog(@"END LINES: me=%ld jpeg=%ld", src_mgr.writtenLines, src_mgr.cinfo.output_scanline);
	BOOL ret = (src_mgr.cinfo.output_scanline == src_mgr.cinfo.image_height) || failed;
	
	if(ret) {
		jpeg_finish_decompress(&src_mgr.cinfo);
		if(!failed) {
			assert(jpeg_input_complete(&src_mgr.cinfo));
			ret = [self partialTile:YES];
		}
	}
	return ret;
}

- (BOOL)partialTile:(BOOL)final
{
	imageMemory *im = ims;
	for(size_t idx=0; idx<zoomLevels; ++idx, ++im) {
		// got enought to tile one row now?
		if(final || (im->outLine && !(im->outLine % TILE_SIZE))) {
			size_t rows = im->rows;		// cheat
			if(!final) im->rows = im->row + 1;		// just do one tile row
			failed = !tileBuilder(im, YES, flushDiskCache || only256M_memory);
			if(failed) {
				return NO;
			}
			++im->row;
			im->rows = rows;
		}
		if(final) {
			truncateEmptySpace(im);
			if(flushDiskCache || only256M_memory) {
				int fd = im->map.fd;
				assert(fd != -1);
				int32_t file_size = (int32_t)lseek(fd, 0, SEEK_END);
				OSAtomicAdd32(file_size, &ubc_usage);

				if(ubc_usage > 50*1000*1000) {
					if(OSAtomicCompareAndSwap32(0, 1, &fileFlushGroupSuspended)) {
						dispatch_suspend(fileFlushGroup);
						dispatch_group_async(fileFlushGroup, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{ NSLog(@"unblocked!"); } );
					}
				}
				dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^
					{
						// need to make sure file is kept open til we flush - who knows what will happen otherwise
						int ret = fcntl(fd,  F_FULLFSYNC);
						if(ret == -1) NSLog(@"ERROR: failed to sync fd=%d", fd);
						OSAtomicAdd32(-file_size, &ubc_usage);
						
						if(ubc_usage <= 50*1000*1000) {
							if(OSAtomicCompareAndSwap32(1, 0, &fileFlushGroupSuspended)) {
								dispatch_resume(fileFlushGroup);
							}
						}
					} );
			}
		}
	}
	return YES;
}
#endif

- (void)decodeImageURL:(NSURL *)url
{
	//NSLog(@"URL=%@", url);
#ifdef LIBJPEG
	if(decoder == libjpegTurboDecoder) {
		NSData *data = [NSData dataWithContentsOfURL:url];
		[self decodeImageData:data];
	} else
#endif
	if(decoder == cgimageDecoder) {
		failed = YES;
		CGImageSourceRef imageSourcRef = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
		if(imageSourcRef) {
			CGImageRef image = CGImageSourceCreateImageAtIndex(imageSourcRef, 0, NULL);
			CFRelease(imageSourcRef), imageSourcRef = NULL;
			if(image) {
				failed = NO;
				[self decodeImage:image];
				CGImageRelease(image);
			}
		}
	}
}

- (void)decodeImage:(CGImageRef)image
{
	assert(decoder == cgimageDecoder);
	[self mapMemoryForIndex:0 width:CGImageGetWidth(image) height:CGImageGetHeight(image)];
	[self drawImage:image];
	if(!failed) [self run];
}

#ifdef LIBJPEG
- (void)decodeImageData:(NSData *)data
{
	assert(decoder == libjpegTurboDecoder);
	
	tjhandle decompressor = tjInitDecompress();

	unsigned char *jpegBuf = (unsigned char *)[data bytes];
	unsigned long jpegSize = [data length];
	int jwidth, jheight, jpegSubsamp;
	failed = (BOOL)tjDecompressHeader2(decompressor,
		jpegBuf,
		jpegSize,
		&jwidth,
		&jheight,
		&jpegSubsamp 
		);
	if(!failed) {
		[self mapMemoryForIndex:0 width:jwidth height:jheight];

		failed = (BOOL)tjDecompress2(decompressor,
			jpegBuf,
			jpegSize,
			ims[0].map.addr,
			jwidth,
			ims[0].map.bytesPerRow,
			jheight,
			TJPF_ABGR,
			TJFLAG_NOREALLOC
			);
		tjDestroy(decompressor);
	}

	if(!failed) [self run];
}
#endif

- (CGSize)imageSize
{
	return CGSizeMake(ims[0].map.width, ims[0].map.height);
}

- (BOOL)createImageFile
{
	BOOL success;
	int fd = [self createTempFile:NO size:0];
	if(fd == -1) {
		failed = YES;
		success = NO;
	} else {
		if ((imageFile = fdopen(fd, "r+")) == NULL) {
			NSLog(@"Error: failed to fdopen image file \"%@\" for \"r+\" (%d).", imagePath, errno);
			close(fd);
			failed = YES;
			success = NO;
		} else {
			success = YES;
		}
	}
	return success;
}

- (int)createTempFile:(BOOL)unlinkFile size:(size_t)size
{
	char *template = strdup([[NSTemporaryDirectory() stringByAppendingPathComponent:@"imXXXXXX"] fileSystemRepresentation]);
	int fd = mkstemp(template);
	if(fd == -1) {
		failed = YES;
		NSLog(@"OPEN failed file %s %s", template, strerror(errno));
	} else {
		if(unlinkFile) {
			unlink(template);	// so it goes away when the fd is closed or on a crash

#if 0			
			// have to expand the file to correct size first
			lseek(mapP->fd, mapP->mappedSize - 1, SEEK_SET);
			char tmp = 0;
			write(mapP->fd, &tmp, 1);
#endif
			int ret = fcntl(fd, F_RDAHEAD, 0);	// don't clog up the system's disk cache
			if(ret == -1) {
				NSLog(@"Warning: cannot turn off F_RDAHEAD for input file (errno %d).", errno);
			}

			fstore_t fst;
			fst.fst_flags      = F_ALLOCATECONTIG;  // could add F_ALLOCATEALL?
			fst.fst_posmode    = F_PEOFPOSMODE;     // allocate from EOF (0)
			fst.fst_offset     = 0;                 // offset relative to the EOF
			fst.fst_length     = size;
			fst.fst_bytesalloc = 0;                 // why not but is not needed

			ret = fcntl(fd, F_PREALLOCATE, &fst);
			if(ret == -1) {
				NSLog(@"Warning: cannot F_PREALLOCATE for input file (errno %d).", errno);
			}
	
			ret = ftruncate(fd, size);				// Now the file is there for sure
			if(ret == -1) {
				NSLog(@"Warning: cannot ftruncate input file (errno %d).", errno);
			}
		} else {
			imagePath = [NSString stringWithCString:template encoding:NSASCIIStringEncoding];
			
			int ret = fcntl(fd, F_NOCACHE, 1);	// don't clog up the system's disk cache
			if(ret == -1) {
				NSLog(@"Warning: cannot turn off cacheing for input file (errno %d).", errno);
			}
		}
	}
	free(template);

	return fd;
}
- (void)mapMemoryForIndex:(size_t)idx width:(size_t)w height:(size_t)h
{
NSLog(@"WAIT on fileFlushGroup...");
//	dispatch_group_wait(fileFlushGroup, DISPATCH_TIME_FOREVER);
NSLog(@"...wait done");

	imageMemory *imsP = &ims[idx];
	
	imsP->map.width = w;
	imsP->map.height = h;
	
	imsP->index = idx;
	imsP->rows = calcDimension(imsP->map.height)/tileDimension;
	imsP->cols = calcDimension(imsP->map.width)/tileDimension;
	
	mapper *mapP = &imsP->map;
	mapP->bytesPerRow = calcBytesPerRow(mapP->width);
	mapP->emptyTileRowSize = mapP->bytesPerRow * tileDimension;
	mapP->mappedSize = mapP->bytesPerRow * calcDimension(mapP->height) + mapP->emptyTileRowSize;	// may need temp space

	if(mapP->fd <= 0) {
		mapP->fd = [self createTempFile:YES  size:mapP->mappedSize];
		if(mapP->fd == -1) return;
	}

	// NSLog(@"imageSize=%ld", imageSize);
	if(mapWholeFile && !mapP->emptyAddr) {
		mapP->emptyAddr = mmap(NULL, mapP->mappedSize, PROT_READ | PROT_WRITE, MAP_FILE | MAP_SHARED | MAP_NOCACHE, mapP->fd, 0); //  | MAP_NOCACHE
		mapP->addr = mapP->emptyAddr + mapP->emptyTileRowSize;
		if(mapP->emptyAddr == MAP_FAILED) {
			failed = YES;
			NSLog(@"errno3=%s", strerror(errno) );
			mapP->emptyAddr = NULL;
			mapP->addr = NULL;
			mapP->mappedSize = 0;
		}
#if MMAP_DEBUGGING == 1
		NSLog(@"MMAP[%d]: addr=%p 0x%X bytes", mapP->fd, mapP->emptyAddr, (NSUInteger)mapP->mappedSize);
#endif
	}
}

- (void)drawImage:(CGImageRef)image
{
	if(image && !failed) {
		assert(ims[0].map.addr);

#if MEMORY_DEBUGGING == 1
		[self freeMemory:@"drawImage start"];
#endif

		madvise(ims[0].map.addr, ims[0].map.mappedSize-ims[0].map.emptyTileRowSize, MADV_SEQUENTIAL);

		CGContextRef context = CGBitmapContextCreate(ims[0].map.addr, ims[0].map.width, ims[0].map.height, bitsPerComponent, ims[0].map.bytesPerRow, colorSpace, kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Little);	// BRGA flipped (little Endian)
		assert(context);
		CGContextSetBlendMode(context, kCGBlendModeCopy); // Apple uses this in QA1708
		CGRect rect = CGRectMake(0, 0, ims[0].map.width, ims[0].map.height);
		CGContextDrawImage(context, rect, image);
		CGContextRelease(context);

		madvise(ims[0].map.addr, ims[0].map.mappedSize-ims[0].map.emptyTileRowSize, MADV_FREE); // MADV_DONTNEED

#if MEMORY_DEBUGGING == 1
		[self freeMemory:@"drawImage done"];
#endif
	}
}

- (void)run
{
	mapper *lastMap = NULL;
	mapper *currMap = NULL;

	for(NSUInteger idx=0; idx < zoomLevels; ++idx) {
		lastMap = currMap;	// unused first loop
		currMap = &ims[idx].map;
		if(idx) {
			[self mapMemoryForIndex:idx width:lastMap->width/2 height:lastMap->height/2];
			if(failed) return;

//dumpIMS("RUN", &ims[idx]);

#if USE_VIMAGE == 1
		   vImage_Buffer src = {
				.data = lastMap->addr,
				.height = lastMap->height,
				.width = lastMap->width,
				.rowBytes = lastMap->bytesPerRow
			};
			
		   vImage_Buffer dest = {
				.data = currMap->addr,
				.height = currMap->height,
				.width = currMap->width,
				.rowBytes = currMap->bytesPerRow
			};

			vImage_Error err = vImageScale_ARGB8888 (
			   &src,
			   &dest,
			   NULL,
			   0 // kvImageHighQualityResampling 
			);
			assert(err == kvImageNoError);
#else	
			// Take every other pixel, every other row, to "down sample" the image. This is fast but has known problems.
			// Got a better idea? Submit a pull request.
			madvise(lastMap->addr, lastMap->mappedSize-lastMap->emptyTileRowSize, MADV_SEQUENTIAL);
			madvise(currMap->addr, currMap->mappedSize-currMap->emptyTileRowSize, MADV_SEQUENTIAL);

			uint32_t *inPtr = (uint32_t *)lastMap->addr;
			uint32_t *outPtr = (uint32_t *)currMap->addr;
			for(size_t row=0; row<currMap->height; ++row) {
				char *lastInPtr = (char *)inPtr;
				char *lastOutPtr = (char *)outPtr;
				for(size_t col = 0; col < currMap->width; ++col) {
					*outPtr++ = *inPtr;
					inPtr += 2;
				}
				inPtr = (uint32_t *)(lastInPtr + lastMap->bytesPerRow*2);
				outPtr = (uint32_t *)(lastOutPtr + currMap->bytesPerRow);
			}

			madvise(lastMap->addr, lastMap->mappedSize-lastMap->emptyTileRowSize, MADV_FREE);
			madvise(currMap->addr, currMap->mappedSize-currMap->emptyTileRowSize, MADV_FREE);
#endif
			// make tiles
			BOOL ret = tileBuilder(&ims[idx-1], NO, flushDiskCache || only256M_memory);
			if(!ret) goto eRR;
		}
	}
	assert(zoomLevels);
	failed = !tileBuilder(&ims[zoomLevels-1], NO, flushDiskCache || only256M_memory);
	return;
	
  eRR:
	failed = YES;
	return;
}

- (UIImage *)tileForScale:(CGFloat)scale row:(int)row col:(int)col
{
	CGImageRef image = [self newImageForScale:scale row:row col:col];
	UIImage *img = [UIImage imageWithCGImage:image];
	CGImageRelease(image);
	return img;
}
- (CGImageRef)newImageForScale:(CGFloat)scale row:(int)row col:(int)col
{
	if(failed) return nil;

	long idx = offsetFromScale(scale);
	imageMemory *im = (imageMemory *)malloc(sizeof(imageMemory));
	memcpy(im, &ims[idx], sizeof(imageMemory));
	im->col = col;
	im->row = row;

	size_t x = col * tileDimension;
	size_t y = row * tileDimension;
	
	im->tileWidth = MIN(im->map.width-x, tileDimension);
	im->tileHeight = MIN(im->map.height-y, tileDimension);

	size_t imgSize = tileBytesPerRow*im->tileHeight;
	struct CGDataProviderDirectCallbacks callBacks = { 0, 0, 0, PhotoScrollerProviderGetBytesAtPosition, PhotoScrollerProviderReleaseInfoCallback};
	CGDataProviderRef dataProvider = CGDataProviderCreateDirect(im, imgSize, &callBacks);
	
	CGImageRef image = CGImageCreate (
	   im->tileWidth,
	   im->tileHeight,
	   bitsPerComponent,
	   4*bitsPerComponent,
	   tileBytesPerRow,
	   colorSpace,
	   kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Little,
	   dataProvider,
	   NULL,
	   false,
	   kCGRenderingIntentPerceptual
	);
	CGDataProviderRelease(dataProvider);
	return image;
}


- (uint64_t)freeDiskspace
{
	// http://stackoverflow.com/questions/5712527
    uint64_t totalSpace = 0;
    uint64_t totalFreeSpace = 0;

    __autoreleasing NSError *error = nil;  
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);  
    NSDictionary *dictionary = [[NSFileManager defaultManager] attributesOfFileSystemForPath:[paths lastObject] error: &error];  

    if (dictionary) {  
        NSNumber *fileSystemSizeInBytes = [dictionary objectForKey: NSFileSystemSize];  
        NSNumber *freeFileSystemSizeInBytes = [dictionary objectForKey:NSFileSystemFreeSize];
        totalSpace = [fileSystemSizeInBytes unsignedLongLongValue];
        totalFreeSpace = [freeFileSystemSizeInBytes unsignedLongLongValue];
        NSLog(@"Disk Capacity of %llu MiB with %llu MiB free disk available.", ((totalSpace/1024ll)/1024ll), ((totalFreeSpace/1024ll)/1024ll));
    } else {  
        NSLog(@"Error Obtaining System Memory Info: Domain = %@, Code = %@", [error domain], [error code]);  
    }  

    return totalFreeSpace;
}

- (freeMemory)freeMemory:(NSString *)msg
{
	// http://stackoverflow.com/questions/5012886
    mach_port_t host_port;
    mach_msg_type_number_t host_size;
    vm_size_t pagesize;
	freeMemory fm = { 0, 0, 0, 0, 0 };

    host_port = mach_host_self();
    host_size = sizeof(vm_statistics_data_t) / sizeof(integer_t);
    host_page_size(host_port, &pagesize);        

    vm_statistics_data_t vm_stat;

    if (host_statistics(host_port, HOST_VM_INFO, (host_info_t)&vm_stat, &host_size) != KERN_SUCCESS) {
        NSLog(@"Failed to fetch vm statistics");
	} else {
		/* Stats in bytes */ 
		natural_t mem_used = (vm_stat.active_count +
							  vm_stat.inactive_count +
							  vm_stat.wire_count) * pagesize;
		natural_t mem_free = vm_stat.free_count * pagesize;
		natural_t mem_total = mem_used + mem_free;
		
		fm.freeMemory = (size_t)mem_free;
		fm.usedMemory = (size_t)mem_used;
		fm.totlMemory = (size_t)mem_total;
		
		struct task_basic_info info;
		if(dump_memory_usage(&info)) {
			fm.resident_size = (size_t)info.resident_size;
			fm.virtual_size = (size_t)info.virtual_size;
		}
		
		NSLog(@"%@:   "
			"total: %u "
			"used: %u "
			"FREE: %u "
"cows %u "
"faoults %u "
"purgeable_count %u "
"speculative_count %u "
			"  [resident=%u virtual=%u]", 
			msg, 
			(unsigned int)mem_total, 
			(unsigned int)mem_used, 
			(unsigned int)mem_free, 
(unsigned int)vm_stat.cow_faults,
(unsigned int)vm_stat.faults,
(unsigned int)vm_stat.purgeable_count,
(unsigned int)vm_stat.speculative_count,

			(unsigned int)fm.resident_size, 
			(unsigned int)fm.virtual_size
			
		);


		size_t vmsLen = 0;
		int ret = sysctlbyname("kern.vnode", NULL, &vmsLen, NULL, 0);
		NSLog(@"sysctlbyname: vnodes=%d ret=%d", (int)vmsLen, ret);
 		
#if 0
	natural_t	free_count;		/* # of pages free */
	natural_t	active_count;		/* # of pages active */
	natural_t	inactive_count;		/* # of pages inactive */
	natural_t	wire_count;		/* # of pages wired down */
	natural_t	zero_fill_count;	/* # of zero fill pages */
	natural_t	reactivations;		/* # of pages reactivated */
	natural_t	pageins;		/* # of pageins */
	natural_t	pageouts;		/* # of pageouts */
	natural_t	faults;			/* # of faults */
	natural_t	cow_faults;		/* # of copy-on-writes */
	natural_t	lookups;		/* object cache lookups */
	natural_t	hits;			/* object cache hits */

	/* added for rev1 */
	natural_t	purgeable_count;	/* # of pages purgeable */
	natural_t	purges;			/* # of pages purged */

	/* added for rev2 */
	/*
	 * NB: speculative pages are already accounted for in "free_count",
	 * so "speculative_count" is the number of "free" pages that are
	 * used to hold data that was read speculatively from disk but
	 * haven't actually been used by anyone so far.
	 */
	natural_t	speculative_count;	/* # of pages speculative */
#endif		
		
		
		
		
		
		
	}
	return fm;
}



@end

static freeMemory freeMem(NSString *msg)
{
	// http://stackoverflow.com/questions/5012886
    mach_port_t host_port;
    mach_msg_type_number_t host_size;
    vm_size_t pagesize;
	freeMemory fm = { 0, 0, 0, 0, 0 };

    host_port = mach_host_self();
    host_size = sizeof(vm_statistics_data_t) / sizeof(integer_t);
    host_page_size(host_port, &pagesize);        

    vm_statistics_data_t vm_stat;

    if (host_statistics(host_port, HOST_VM_INFO, (host_info_t)&vm_stat, &host_size) != KERN_SUCCESS) {
        NSLog(@"Failed to fetch vm statistics");
	} else {
		/* Stats in bytes */ 
		natural_t mem_used = (vm_stat.active_count +
							  vm_stat.inactive_count +
							  vm_stat.wire_count) * pagesize;
		natural_t mem_free = vm_stat.free_count * pagesize;
		natural_t mem_total = mem_used + mem_free;
		
		fm.freeMemory = (size_t)mem_free;
		fm.usedMemory = (size_t)mem_used;
		fm.totlMemory = (size_t)mem_total;
		
		struct task_basic_info info;
		if(dump_memory_usage(&info)) {
			fm.resident_size = (size_t)info.resident_size;
			fm.virtual_size = (size_t)info.virtual_size;
		}
		
		NSLog(@"%@:   total: %u used: %u FREE: %u   [resident=%u virtual=%u]", msg, (unsigned int)mem_total, (unsigned int)mem_used, (unsigned int)mem_free, (unsigned int)fm.resident_size, (unsigned int)fm.virtual_size);

		size_t vmsLen = 0;
		int ret = sysctlbyname("kern.vnode", NULL, &vmsLen, NULL, 0);
		NSLog(@"sysctlbyname: vnodes=%d ret=%d", (int)vmsLen, ret);
	}
	return fm;
}

static BOOL dump_memory_usage(struct task_basic_info *info) {
  mach_msg_type_number_t size = sizeof( struct task_basic_info );
  kern_return_t kerr = task_info( mach_task_self(), TASK_BASIC_INFO, (task_info_t)info, &size );
  return ( kerr == KERN_SUCCESS );
}

static size_t PhotoScrollerProviderGetBytesAtPosition (
    void *info,
    void *buffer,
    off_t position,
    size_t origCount
) {
	imageMemory *im = (imageMemory *)info;

	size_t mapSize = tileDimension*tileBytesPerRow;
	// Don't think caching here would help but didn't test myself.
	unsigned char *startPtr = mmap(NULL, mapSize, PROT_READ, MAP_FILE | MAP_SHARED | MAP_NOCACHE, im->map.fd, (im->row*im->cols + im->col) * mapSize);  /*| MAP_NOCACHE */
	if(startPtr == MAP_FAILED) {
		NSLog(@"errno4=%s", strerror(errno) );
		return 0;
	}

	memcpy(buffer, startPtr+position, origCount);	// blit the image, then quit. How nice is that!
	munmap(startPtr, mapSize);

	return origCount;
}

static void PhotoScrollerProviderReleaseInfoCallback (
    void *info
) {
	free(info);
}

static BOOL tileBuilder(imageMemory *im, BOOL useMMAP, BOOL fullSync)
{
	unsigned char *optr = im->map.emptyAddr;
	unsigned char *iptr = im->map.addr;
	
	// NSLog(@"tile...");
	// Now, we are going to pre-tile the image in 256x256 tiles, so we can map in contigous chunks of memory
	for(size_t row=im->row; row<im->rows; ++row) {
		unsigned char *tileIptr;
		if(useMMAP) {
			im->map.mappedSize = im->map.emptyTileRowSize*2;	// two tile rows
			im->map.emptyAddr = mmap(NULL, im->map.mappedSize, PROT_READ | PROT_WRITE, MAP_FILE | MAP_SHARED | MAP_NOCACHE, im->map.fd, row*im->map.emptyTileRowSize);  /*| MAP_NOCACHE */
			if(im->map.emptyAddr == MAP_FAILED) return NO;
#if MMAP_DEBUGGING == 1
			NSLog(@"MMAP[%d]: addr=%p 0x%X bytes", im->map.fd, im->map.emptyAddr, (NSUInteger)im->map.mappedSize);
#endif	
			im->map.addr = im->map.emptyAddr + im->map.emptyTileRowSize;
			
			iptr = im->map.addr;
			optr = im->map.emptyAddr;
			tileIptr = im->map.emptyAddr;
		} else {
			tileIptr = iptr;
		}
		for(size_t col=0; col<im->cols; ++col) {
			unsigned char *lastIptr = iptr;
			for(size_t i=0; i<tileDimension; ++i) {
				memcpy(optr, iptr, tileBytesPerRow);
				iptr += im->map.bytesPerRow;
				optr += tileBytesPerRow;
			}
			iptr = lastIptr + tileBytesPerRow;	// move to the next image
		}
		if(useMMAP) {
//int mret = msync(im->map.emptyAddr, im->map.mappedSize, MS_ASYNC);
//assert(mret == 0);
			int ret = munmap(im->map.emptyAddr, im->map.mappedSize);
#if MMAP_DEBUGGING == 1
			NSLog(@"UNMAP[%d]: addr=%p 0x%X bytes", im->map.fd, im->map.emptyAddr, (NSUInteger)im->map.mappedSize);
#endif
			assert(ret == 0);
		} else {
			iptr = tileIptr + im->map.emptyTileRowSize;
		}
	}
	//NSLog(@"...tile");

	if(!useMMAP) {
		// OK we're done with this memory now
//int mret = msync(im->map.emptyAddr, im->map.mappedSize, MS_ASYNC);
//assert(mret == 0);
		int ret = munmap(im->map.emptyAddr, im->map.mappedSize);
#if MMAP_DEBUGGING == 1
		NSLog(@"UNMAP[%d]: addr=%p 0x%X bytes", im->map.fd, im->map.emptyAddr, (NSUInteger)im->map.mappedSize);
#endif
		assert(ret==0);

		// don't need the scratch space now
		truncateEmptySpace(im);

		if(fullSync) {
#if 1
			NSLog(@"Start sync...");
			int ret = fcntl(im->map.fd,  F_FULLFSYNC);
			if(ret == -1) NSLog(@"ERROR: failed to sync fd=%d", im->map.fd);
			else NSLog(@"SYNC DONE: %d", im->map.fd);
#else
			int fd = im->map.fd;
			assert(fd != -1);
			int32_t file_size = (int32_t)lseek(fd, 0, SEEK_END);
			OSAtomicAdd32Barrier(file_size, &ubc_usage);
NSLog(@"USAGE:    %d", ubc_usage);
			if(ubc_usage > 50*1000*1000) {
			
				if(OSAtomicCompareAndSwap32(0, 1, &fileFlushGroupSuspended)) {
					dispatch_suspend(fileFlushGroup);
					dispatch_group_async(fileFlushGroup, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{ NSLog(@"unblocked!"); } );
				}
			}
			dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^
				{
					// need to make sure file is kept open til we flush - who knows what will happen otherwise
					int ret = fcntl(fd,  F_FULLFSYNC);
					if(ret == -1) NSLog(@"ERROR: failed to sync fd=%d", fd);
					OSAtomicAdd32Barrier(-file_size, &ubc_usage);

					if(ubc_usage <= 50*1000*1000) {
						if(OSAtomicCompareAndSwap32(1, 0, &fileFlushGroupSuspended)) {
							dispatch_resume(fileFlushGroup);
						}
					}
				} );

#endif
		}
	}
	return YES;
}

static void truncateEmptySpace(imageMemory *im)
{
	// don't need the scratch space now
	off_t properLen = lseek(im->map.fd, 0, SEEK_END) - im->map.emptyTileRowSize;
	int ret = ftruncate(im->map.fd, properLen);
	if(ret) {
		NSLog(@"Failed to truncate file!");
	}
	im->map.mappedSize = 0;	// force errors if someone tries to use mmap now
}

#ifdef LIBJPEG
static void my_error_exit(j_common_ptr cinfo)
{
  /* cinfo->err really points to a my_error_mgr struct, so coerce pointer */
  my_error_ptr myerr = (my_error_ptr) cinfo->err;

  /* Always display the message. */
  /* We could postpone this until after returning, if we chose. */
  (*cinfo->err->output_message) (cinfo);

  /* Return control to the setjmp point */
  longjmp(myerr->setjmp_buffer, 1);
}

static void init_source(j_decompress_ptr cinfo)
{
	co_jpeg_source_mgr *src = (co_jpeg_source_mgr *)cinfo->src;
	src->start_of_stream = TRUE;
}

static boolean fill_input_buffer(j_decompress_ptr cinfo)
{
	co_jpeg_source_mgr *src = (co_jpeg_source_mgr *)cinfo->src;

	size_t diff = src->consumed_data - src->deleted_data;
	size_t unreadLen = src->data_length - diff;
	//NSLog(@"unreadLen=%ld", unreadLen);
	if((long)unreadLen <= 0) {
		return FALSE;
	}
	src->pub.bytes_in_buffer = unreadLen;
	
	src->pub.next_input_byte = src->data + diff;
	src->consumed_data = src->data_length + src->deleted_data;

	src->start_of_stream = FALSE;
	//NSLog(@"returning %ld bytes consumed_data=%ld data_length=%ld deleted_data=%ld", unreadLen, src->consumed_data, src->data_length, src->deleted_data);

	return TRUE;
}

static void skip_input_data(j_decompress_ptr cinfo, long num_bytes)
{
	co_jpeg_source_mgr *src = (co_jpeg_source_mgr *)cinfo->src;

	if (num_bytes > 0) {
		if(num_bytes <= (long)src->pub.bytes_in_buffer) {
			//NSLog(@"SKIPPER1: %ld", num_bytes);
			src->pub.next_input_byte += (size_t)num_bytes;
			src->pub.bytes_in_buffer -= (size_t)num_bytes;
		} else {
			//NSLog(@"SKIPPER2: %ld", num_bytes);
			src->consumed_data			+= num_bytes - src->pub.bytes_in_buffer;
			src->pub.bytes_in_buffer	= 0;
		}
	}
}

static boolean resync_to_restart(j_decompress_ptr cinfo, int desired)
{
	co_jpeg_source_mgr *src = (co_jpeg_source_mgr *)cinfo->src;
	// NSLog(@"YIKES: resync_to_restart!!!");

	src->jpegFailed = TRUE;
	return FALSE;
}

static void term_source(j_decompress_ptr cinfo)
{
}

#endif

