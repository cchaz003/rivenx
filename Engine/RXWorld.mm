//
//  RXWorld.mm
//  rivenx
//
//  Created by Jean-Francois Roy on 25/08/2005.
//  Copyright 2005 MacStorm. All rights reserved.
//

#import <mach/task.h>
#import <mach/thread_act.h>
#import <mach/thread_policy.h>

#import <sys/param.h>
#import <sys/mount.h>

#import "Base/RXThreadUtilities.h"
#import "Base/RXTiming.h"
#import "Base/RXLogCenter.h"

#import "Engine/RXWorld.h"
#import "Engine/RXCursors.h"

#import "Utilities/GTMObjectSingleton.h"
#import "Utilities/BZFSUtilities.h"

#import "Rendering/Audio/RXAudioRenderer.h"

#import "States/RXCardState.h"

NSObject* g_world = nil;


@interface RXWorld (RXWorldPrivate)
- (void)_secondStageInit;
@end

@interface RXWorld (RXWorldRendering)
- (void)_initializeRendering;
- (void)_toggleFullscreen;
@end

@implementation RXWorld

// disable automatic KVC
+ (BOOL)accessInstanceVariablesDirectly {
    return NO;
}

- (void)_initEngineVariables {
    NSError* error = nil;
    NSData* default_vars_data = [NSData dataWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"EngineVariables" ofType:@"plist"] options:0 error:&error];
    if (!default_vars_data)
        @throw [NSException exceptionWithName:@"RXMissingDefaultEngineVariablesException"
                                       reason:@"Unable to find EngineVariables.plist."
                                     userInfo:[NSDictionary dictionaryWithObject:error forKey:NSUnderlyingErrorKey]];
    
    NSString* error_str = nil;
    _engineVariables = [[NSPropertyListSerialization propertyListFromData:default_vars_data
                                                         mutabilityOption:NSPropertyListMutableContainers
                                                                   format:NULL
                                                         errorDescription:&error_str] retain];
    if (!_engineVariables)
        @throw [NSException exceptionWithName:@"RXInvalidDefaultEngineVariablesException"
                                       reason:@"Unable to load the default engine variables."
                                     userInfo:[NSDictionary dictionaryWithObject:error_str forKey:@"RXErrorString"]];
    [error_str release];
    
    NSDictionary* user_vars = [[NSUserDefaults standardUserDefaults] objectForKey:@"EngineVariables"];
    if (user_vars) {
        NSEnumerator* keypaths = [user_vars keyEnumerator];
        NSString* keypath;
        while ((keypath = [keypaths nextObject]))
            [_engineVariables setValue:[user_vars objectForKey:keypath] forKeyPath:keypath];
    } else
        [[NSUserDefaults standardUserDefaults] setValue:[NSMutableDictionary dictionary] forKey:@"EngineVariables"];
}

- (void)_initEngineLocations {
    NSError* error;
    
    // world base is the parent directory of the application bundle
    _worldBase = (NSURL*)CFURLCreateWithFileSystemPath(NULL, (CFStringRef)[[[NSBundle mainBundle] bundlePath] stringByDeletingLastPathComponent], kCFURLPOSIXPathStyle, true);
    
    // the world user base is a "Riven X" folder inside the user's Documents folder
    NSString* userBase = [[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0] stringByAppendingPathComponent:@"Riven X"];
    if (!BZFSDirectoryExists(userBase)) {
        BOOL success = BZFSCreateDirectory(userBase, &error);
        if (!success)
            @throw [NSException exceptionWithName:@"RXFilesystemException"
                                           reason:@"Riven X was unable to create its saved games folder in your Documents folder."
                                         userInfo:[NSDictionary dictionaryWithObjectsAndKeys:error, NSUnderlyingErrorKey, nil]];
    }
    _worldUserBase = (NSURL*)CFURLCreateWithFileSystemPath(NULL, (CFStringRef)userBase, kCFURLPOSIXPathStyle, true);
    
    FSRef sharedFolderRef;
    if (FSFindFolder(kLocalDomain, kSharedUserDataFolderType, kDontCreateFolder, &sharedFolderRef) != noErr) {
        @throw [NSException exceptionWithName:@"RXFilesystemException"
                                       reason:@"Riven X was unable to locate your Mac's Shared folder."
                                     userInfo:[NSDictionary dictionaryWithObjectsAndKeys:error, NSUnderlyingErrorKey, nil]];
    }
    
    NSURL* sharedFolderURL = [(NSURL*)CFURLCreateFromFSRef(kCFAllocatorDefault, &sharedFolderRef) autorelease];
    assert(sharedFolderURL);
    
    // the world shared base is a "Riven X" folder inside the /Users/Shared directory
    NSString* sharedBase = [[sharedFolderURL path] stringByAppendingPathComponent:@"Riven X"];
    if (!BZFSDirectoryExists(sharedBase)) {
        BOOL success = BZFSCreateDirectoryExtended(sharedBase, @"admin", 0775, &error);
        if (!success)
            @throw [NSException exceptionWithName:@"RXFilesystemException"
                                           reason:@"Riven X was unable to create its shared support folder in your Mac's Shared folder."
                                         userInfo:[NSDictionary dictionaryWithObjectsAndKeys:error, NSUnderlyingErrorKey, nil]];
    }
    _worldSharedBase = (NSURL*)CFURLCreateWithFileSystemPath(NULL, (CFStringRef)sharedBase, kCFURLPOSIXPathStyle, true);
}

- (void)observeValueForKeyPath:(NSString*)keyPath ofObject:(id)object change:(NSDictionary*)change context:(void*)context {
    if (context == [_engineVariables objectForKey:@"rendering"]) {
        if ([keyPath isEqualToString:@"volume"])
            reinterpret_cast<RX::AudioRenderer*>(_audioRenderer)->SetGain([[change objectForKey:NSKeyValueChangeNewKey] floatValue]);
    }
    else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}


GTMOBJECT_SINGLETON_BOILERPLATE(RXWorld, sharedWorld)

- (id)init {
    self = [super init];
    if (!self)
        return nil;
    
    @try {
        _tornDown = NO;
        
        // WARNING: the world has to run on the main thread
        if (!pthread_main_np())
            @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"initSingleton: MAIN THREAD ONLY" userInfo:nil];
        
        // initialize threading
        RXInitThreading();
        RXSetThreadName("main");
        
        // initialize timing
        RXTimingUpdateTimebase();
        
        // initialize logging
        [RXLogCenter sharedLogCenter];
        
        RXOLog2(kRXLoggingEngine, kRXLoggingLevelMessage, @"I am the first and the last, the alpha and the omega, the beginning and the end.");
        RXOLog2(kRXLoggingEngine, kRXLoggingLevelMessage, @"Riven X version %@ (%@)",
            [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
            [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"]);
        
        // set the global to ourselves
        g_world = self;
        
        // second stage initialization
        [self _secondStageInit];
    } @catch (NSException* e) {
        [[NSApp delegate] performSelectorOnMainThread:@selector(notifyUserOfFatalException:) withObject:e waitUntilDone:NO];
        [self release];
        self = nil;
    }
    
    return self;
}

- (void)_secondStageInit {
    @try {
        // seed random
        srandom(time(NULL));
    
        // initialize the engine variables
        _engineVariablesLock = OS_SPINLOCK_INIT;
        [self _initEngineVariables];
        
        // initialize engine location URLs (the bases)
        [self _initEngineLocations];
        
        // the active stacks dictionary maps stack keys (e.g. aspit, etc.) to RXStack objects
        _activeStacks = [NSMutableDictionary new];
        
        // load Extras.plist
        _extrasDescriptor = [[NSDictionary alloc] initWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"Extras" ofType:@"plist"]];
        if (!_extrasDescriptor)
            @throw [NSException exceptionWithName:@"RXMissingResourceException" reason:@"Failed to load Extras.plist." userInfo:nil];
        
        /*  Notes on Extras.MHK
            *
            *  The marble and bottom book / journal icons are described in Extras.plist (Books and Marbles keys)
            *
            *  The credits are 302 and 303 for the standalones, then 304 to 320 for the scrolling composite
        */
        
        // load Stacks.plist
        _stackDescriptors = [[NSDictionary alloc] initWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"Stacks" ofType:@"plist"]];
        if (!_stackDescriptors)
            @throw [NSException exceptionWithName:@"RXMissingResourceException" reason:@"Failed to load Stacks.plist." userInfo:nil];
        
        // load cursors metadata
        NSDictionary* cursorMetadata = [NSDictionary dictionaryWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"Cursors" ofType:@"plist"]];
        if (!cursorMetadata)
            @throw [NSException exceptionWithName:@"RXMissingResourceException" reason:@"Failed to load Cursors.plist." userInfo:nil];
        
        // load cursors
        _cursors = NSCreateMapTable(NSIntMapKeyCallBacks, NSObjectMapValueCallBacks, 20);
        
        NSEnumerator* cursorEnum = [cursorMetadata keyEnumerator];
        NSString* cursorKey;
        while ((cursorKey = [cursorEnum nextObject])) {
            NSPoint cursorHotspot = NSPointFromString([cursorMetadata objectForKey:cursorKey]);
            NSImage* cursorImage = [[NSImage alloc] initWithContentsOfFile:[[NSBundle mainBundle] pathForResource:cursorKey ofType:@"png" inDirectory:@"cursors"]];
            if (!cursorImage)
                @throw [NSException exceptionWithName:@"RXMissingResourceException"
                                               reason:[NSString stringWithFormat:@"Unable to find cursor %@.", cursorKey]
                                             userInfo:nil];
            
            NSCursor* cursor = [[NSCursor alloc] initWithImage:cursorImage hotSpot:cursorHotspot];
            uintptr_t key = [cursorKey intValue];
            NSMapInsert(_cursors, (const void*)key, (const void*)cursor);
            
            [cursor release];
            [cursorImage release];
        }
                
        // the semaphore will be signaled when a thread has setup inter-thread messaging
        kern_return_t kerr = semaphore_create(mach_task_self(), &_threadInitSemaphore, SYNC_POLICY_FIFO, 0);
        if (kerr != 0)
            @throw [NSException exceptionWithName:NSMachErrorDomain reason:@"Could not allocate stack thread init semaphore." userInfo:nil];
        
        // register for card changed notifications
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_activeCardDidChange:) name:@"RXActiveCardDidChange" object:nil];
    } @catch (NSException* e) {
        [[NSApp delegate] performSelectorOnMainThread:@selector(notifyUserOfFatalException:) withObject:e waitUntilDone:NO];
    }
}

- (void)initializeRendering {
    if (_renderingInitialized)
        return;
    
    @try {
        // initialize rendering
        [self _initializeRendering];
        
        // start threads
        [NSThread detachNewThreadSelector:@selector(_RXScriptThreadEntry:) toTarget:self withObject:nil];
        
        // wait for each thread to be running (this needs to be called the same number of times as the number of threads)
        semaphore_wait(_threadInitSemaphore);
        
        _renderingInitialized = YES;
    } @catch (NSException* e) {
        [[NSApp delegate] performSelectorOnMainThread:@selector(notifyUserOfFatalException:) withObject:e waitUntilDone:NO];
    }
}

- (void)dealloc {
    [super dealloc];
}

- (void)tearDown {
    // WARNING: this method can only run on the main thread
    if (!pthread_main_np())
        @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"_tearDown: MAIN THREAD ONLY" userInfo:nil];
    
#if defined(DEBUG)
    RXOLog(@"tearing down");
#endif
    // boolean guard for several methods
    _tornDown = YES;
    
    // terminate notifications
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
    
    // cut window delegate messages
    if (g_worldView)
        [[g_worldView window] setDelegate:nil];
    
    // card renderer
    [_cardRenderer release];
    _cardRenderer = nil;    
    
    // tear the world view down
    [g_worldView tearDown];
    
    // tear the audoo renderer down
    if (_audioRenderer) {
        reinterpret_cast<RX::AudioRenderer*>(_audioRenderer)->Stop();
        delete reinterpret_cast<RX::AudioRenderer*>(_audioRenderer);
        _audioRenderer = 0;
    }
    
    // terminate threads
    if (_scriptThread)
        [self performSelector:@selector(_stopThreadRunloop) inThread:_scriptThread];
    
    // stack thread creation cond / mutex
    semaphore_destroy(mach_task_self(), _threadInitSemaphore);
    
    // extras archive
    [_extrasDescriptor release];
    _extrasDescriptor = nil;
    
    // cursors
    if (_cursors)
        NSFreeMapTable(_cursors);
    _cursors = nil;
    
    // game state
    [_gameState release];
    _gameState = nil;
    
    // world locations
    [_worldBase release];
    _worldBase = nil;
    
    [_worldUserBase release];
    _worldUserBase = nil;
    
    [_worldSharedBase release];
    _worldSharedBase = nil;
    
    // engine variables
    [_engineVariables release];
    _engineVariables = nil;
    
    [_activeStacks release];
    _activeStacks = nil;
}

#pragma mark -

- (void)_RXScriptThreadEntry:(id)object {
    // reference to the thread
    _scriptThread = [NSThread currentThread];
    
    // make the load CGL context default for the script thread
    CGLSetCurrentContext([_worldView loadContext]);
    
    // run the thread
    RXThreadRunLoopRun(_threadInitSemaphore, "script");
}

- (void)_stopThreadRunloop {
    CFRunLoopStop(CFRunLoopGetCurrent());
}

- (NSThread*)scriptThread {
    return _scriptThread;
}

#pragma mark -

- (NSURL*)worldBase {
    return _worldBase;
}

- (NSURL*)worldUserBase {
    return _worldUserBase;
}

- (NSURL*)worldSharedBase {
    return _worldSharedBase;
}

- (NSDictionary*)extraBitmapsDescriptor {
    return _extrasDescriptor;
}

- (NSView <RXWorldViewProtocol> *)worldView {
    return _worldView;
}

- (NSCursor*)defaultCursor {
    return [self cursorForID:RX_CURSOR_FORWARD];
}

- (NSCursor*)openHandCursor {
    return [self cursorForID:RX_CURSOR_OPEN_HAND];
}

- (NSCursor*)invisibleCursor {
    return [self cursorForID:RX_CURSOR_INVISIBLE];
}

- (NSCursor*)cursorForID:(uint16_t)ID {
    uintptr_t key = ID;
    return (NSCursor*)NSMapGet(_cursors, (const void*)key);
}

#pragma mark -

- (void*)audioRenderer {
    return _audioRenderer;
}

- (RXRenderState*)cardRenderer {
    return _cardRenderer;
}

- (BOOL)fullscreen {
    return _fullscreen;
}

- (void)toggleFullscreen {
    _fullscreen = !_fullscreen;
    [[NSUserDefaults standardUserDefaults] setBool:_fullscreen forKey:@"Fullscreen"];
    
    [self _toggleFullscreen];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"RXFullscreenModeChangeNotification" object:nil userInfo:nil];
}

#pragma mark -

- (RXGameState*)gameState {
    return _gameState;
}

- (void)_activeCardDidChange:(NSNotification*)notification {
    // NOTE: WILL RUN ON THE MAIN THREAD
    
    // if we have a new game state to load and we just cleared the active card, do the swap
    if (![notification object] && _gameStateToLoad) {   
        // swap the game state
        [_gameState release];
        _gameState = _gameStateToLoad;
        _gameStateToLoad = nil;
        
        // ensure the rendering and script engine are running
        [self initializeRendering];
        
        // set the active card to that of the new game state
        RXSimpleCardDescriptor* scd = [_gameState currentCard];
        [(RXCardState*)_cardRenderer setActiveCardWithStack:scd->stackKey ID:scd->cardID waitUntilDone:NO];
        
        // fade the card state back in
//        [_stateCompositor fadeInState:_cardState over:1.0 completionDelegate:self completionSelector:@selector(_cardStateWasFadedIn:)];
    }
}

- (void)_cardStateWasFadedIn:(RXRenderState*)state {

}

- (void)_cardStateWasFadedOut:(RXRenderState*)state {
    [(RXCardState*)_cardRenderer clearActiveCardWaitingUntilDone:NO];
}

- (void)loadGameState:(RXGameState*)gameState {
    _gameStateToLoad = [gameState retain];
    [(RXCardState*)_cardRenderer clearActiveCardWaitingUntilDone:NO];
//    [_stateCompositor fadeOutState:_cardState over:1.0 completionDelegate:self completionSelector:@selector(_cardStateWasFadedOut:)];
}

#pragma mark -
#pragma mark stack management

- (NSDictionary*)stackDescriptorForKey:(NSString*)stackKey {
    return [_stackDescriptors objectForKey:stackKey];
}

- (RXStack*)activeStackWithKey:(NSString*)stackKey {
    return [_activeStacks objectForKey:stackKey];
}

- (void)_postStackLoadedNotification:(NSString*)stackKey {
    // WARNING: MUST RUN ON THE MAIN THREAD
    if (!pthread_main_np()) {
        [self performSelectorOnMainThread:@selector(_postStackLoadedNotification:) withObject:stackKey waitUntilDone:NO];
        return;
    }
    
    [[NSNotificationCenter defaultCenter] postNotificationName:@"RXStackDidLoadNotification" object:stackKey userInfo:nil];
}

- (RXStack*)loadStackWithKey:(NSString*)stackKey {
    RXStack* stack = [self activeStackWithKey:stackKey];
    if (stack)
        return stack;
    
    // initialize the stack
    NSError* error;
    stack = [[RXStack alloc] initWithKey:stackKey error:&error];
    if (!stack) {
        error = [NSError errorWithDomain:[error domain] code:[error code] userInfo:[NSDictionary dictionaryWithObjectsAndKeys:
            [error localizedDescription], NSLocalizedDescriptionKey,
            NSLocalizedStringFromTable(@"REINSTALL_EDITION", @"Editions", "reinstall edition"), NSLocalizedRecoverySuggestionErrorKey,
            [NSArray arrayWithObjects:NSLocalizedString(@"QUIT", @"quit"), nil], NSLocalizedRecoveryOptionsErrorKey,
            [NSApp delegate], NSRecoveryAttempterErrorKey,
            error, NSUnderlyingErrorKey,
            nil]];
        [NSApp performSelectorOnMainThread:@selector(presentError:) withObject:error waitUntilDone:NO];
        return nil;
    }
    
    // store the new stack in the active stacks dictionary
    [_activeStacks setObject:stack forKey:stackKey];
    
    // give up ownership of the new stack
    [stack release];
    
    // post the stack loaded notification on the main thread
    [self _postStackLoadedNotification:stackKey];
    
    // return the stack
    return stack;
}

#pragma mark -

- (void)_dumpEngineVariables {
    OSSpinLockLock(&_engineVariablesLock);
    RXOLog(@"dumping engine variables\n%@", _engineVariables);
    OSSpinLockUnlock(&_engineVariablesLock);
}

- (id)valueForEngineVariable:(NSString*)path {
    OSSpinLockLock(&_engineVariablesLock);
    id value = [_engineVariables valueForKeyPath:path];
    OSSpinLockUnlock(&_engineVariablesLock);
    return value;
}

- (void)setValue:(id)value forEngineVariable:(NSString*)path {
    OSSpinLockLock(&_engineVariablesLock);
    [_engineVariables setValue:value forKeyPath:path];
    [[NSUserDefaults standardUserDefaults] setObject:_engineVariables forKey:@"EngineVariables"];
    OSSpinLockUnlock(&_engineVariablesLock);
}

@end
