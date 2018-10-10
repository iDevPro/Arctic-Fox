/* -*- Mode: objc; tab-width: 2; indent-tabs-mode: nil; c-basic-offset: 2 -*- */
/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

#include "mozilla/ArrayUtils.h"

#include "prlog.h"

#include <unistd.h>
#include <math.h>

#include "nsChildView.h"
#include "nsCocoaWindow.h"

#include "mozilla/MiscEvents.h"
#include "mozilla/MouseEvents.h"
#include "mozilla/TextEvents.h"
#include "mozilla/TouchEvents.h"

#include "nsObjCExceptions.h"
#include "nsCOMPtr.h"
#include "nsToolkit.h"
#include "nsCRT.h"

#include "nsFontMetrics.h"
#include "nsIRollupListener.h"
#include "nsViewManager.h"
#include "nsIInterfaceRequestor.h"
#include "nsIFile.h"
#include "nsILocalFileMac.h"
#include "nsGfxCIID.h"
#include "nsIDOMSimpleGestureEvent.h"
#include "nsThemeConstants.h"
#include "nsIWidgetListener.h"
#include "nsIPresShell.h"

#include "nsDragService.h"
#include "nsClipboard.h"
#include "nsCursorManager.h"
#include "nsWindowMap.h"
#include "nsCocoaFeatures.h"
#include "nsCocoaUtils.h"
#include "nsMenuUtilsX.h"
#include "nsMenuBarX.h"
#include "NativeKeyBindings.h"
#include "ComplexTextInputPanel.h"

#include "gfxContext.h"
#include "gfxQuartzSurface.h"
#include "gfxUtils.h"
#include "nsRegion.h"
#include "Layers.h"
#include "ClientLayerManager.h"
#include "mozilla/layers/LayerManagerComposite.h"
#include "GLTextureImage.h"
#include "GLContextProvider.h"
#include "GLContextCGL.h"
#include "GLUploadHelpers.h"
#include "ScopedGLHelpers.h"
#include "HeapCopyOfStackArray.h"
#include "mozilla/layers/APZCTreeManager.h"
#include "mozilla/layers/GLManager.h"
#include "mozilla/layers/CompositorOGL.h"
#include "mozilla/layers/CompositorParent.h"
#include "mozilla/layers/BasicCompositor.h"
#include "gfxUtils.h"
#include "gfxPrefs.h"
#include "mozilla/gfx/2D.h"
#include "mozilla/gfx/BorrowedContext.h"
#ifdef ACCESSIBILITY
#include "nsAccessibilityService.h"
#include "mozilla/a11y/Platform.h"
#endif

#include "mozilla/Preferences.h"

#include <dlfcn.h>

#include <ApplicationServices/ApplicationServices.h>

#include "GoannaProfiler.h"

#include "nsIDOMWheelEvent.h"
#include "mozilla/layers/ChromeProcessController.h"
#include "nsLayoutUtils.h"
#include "InputData.h"
#include "VibrancyManager.h"
#include "nsNativeThemeCocoa.h"

using namespace mozilla;
using namespace mozilla::layers;
using namespace mozilla::gl;
using namespace mozilla::widget;

using mozilla::gfx::Matrix4x4;

#undef DEBUG_UPDATE
#undef INVALIDATE_DEBUGGING  // flash areas as they are invalidated

// Don't put more than this many rects in the dirty region, just fluff
// out to the bounding-box if there are more
#define MAX_RECTS_IN_REGION 100

#ifdef PR_LOGGING
PRLogModuleInfo* sCocoaLog = nullptr;
#endif

extern "C" {
  CG_EXTERN void CGContextResetCTM(CGContextRef);
  CG_EXTERN void CGContextSetCTM(CGContextRef, CGAffineTransform);
  CG_EXTERN void CGContextResetClip(CGContextRef);

  typedef CFTypeRef CGSRegionObj;
  CGError CGSNewRegionWithRect(const CGRect *rect, CGSRegionObj *outRegion);
  CGError CGSNewRegionWithRectList(const CGRect *rects, int rectCount, CGSRegionObj *outRegion);
}

// defined in nsMenuBarX.mm
extern NSMenu* sApplicationMenu; // Application menu shared by all menubars

static bool gChildViewMethodsSwizzled = false;

extern nsISupportsArray *gDraggedTransferables;

ChildView* ChildViewMouseTracker::sLastMouseEventView = nil;
NSEvent* ChildViewMouseTracker::sLastMouseMoveEvent = nil;
NSWindow* ChildViewMouseTracker::sWindowUnderMouse = nil;
NSPoint ChildViewMouseTracker::sLastScrollEventScreenLocation = NSZeroPoint;

#ifdef INVALIDATE_DEBUGGING
static void blinkRect(Rect* r);
static void blinkRgn(RgnHandle rgn);
#endif

bool gUserCancelledDrag = false;

uint32_t nsChildView::sLastInputEventCount = 0;

static uint32_t gNumberOfWidgetsNeedingEventThread = 0;

@interface ChildView(Private)

// sets up our view, attaching it to its owning goanna view
- (id)initWithFrame:(NSRect)inFrame goannaChild:(nsChildView*)inChild;
- (void)forceRefreshOpenGL;

// set up a goanna mouse event based on a cocoa mouse event
- (void) convertCocoaMouseWheelEvent:(NSEvent*)aMouseEvent
                        toGoannaEvent:(WidgetWheelEvent*)outWheelEvent;
- (void) convertCocoaMouseEvent:(NSEvent*)aMouseEvent
                   toGoannaEvent:(WidgetInputEvent*)outGoannaEvent;

- (NSMenu*)contextMenu;

- (BOOL)isRectObscuredBySubview:(NSRect)inRect;

- (void)processPendingRedraws;

- (void)drawRect:(NSRect)aRect inContext:(CGContextRef)aContext;
- (nsIntRegion)nativeDirtyRegionWithBoundingRect:(NSRect)aRect;
- (BOOL)isUsingMainThreadOpenGL;
- (BOOL)isUsingOpenGL;
- (void)drawUsingOpenGL;
- (void)drawUsingOpenGLCallback;

- (BOOL)hasRoundedBottomCorners;
- (CGFloat)cornerRadius;
- (void)clearCorners;

// Overlay drawing functions for traditional CGContext drawing
- (void)drawTitleString;
- (void)drawTitlebarHighlight;
- (void)maskTopCornersInContext:(CGContextRef)aContext;

// Called using performSelector:withObject:afterDelay:0 to release
// aWidgetArray (and its contents) the next time through the run loop.
- (void)releaseWidgets:(NSArray*)aWidgetArray;

#if USE_CLICK_HOLD_CONTEXTMENU
 // called on a timer two seconds after a mouse down to see if we should display
 // a context menu (click-hold)
- (void)clickHoldCallback:(id)inEvent;
#endif

#ifdef ACCESSIBILITY
- (id<mozAccessible>)accessible;
#endif

- (nsIntPoint)convertWindowCoordinates:(NSPoint)aPoint;
- (APZCTreeManager*)apzctm;

- (BOOL)inactiveWindowAcceptsMouseEvent:(NSEvent*)aEvent;
- (void)updateWindowDraggableState;

@end

@interface EventThreadRunner : NSObject
{
  NSThread* mThread;
}
- (id)init;

+ (void)start;
+ (void)stop;

@end

@interface NSView(NSThemeFrameCornerRadius)
- (float)roundedCornerRadius;
@end

@interface NSView(DraggableRegion)
- (CGSRegionObj)_regionForOpaqueDescendants:(NSRect)aRect forMove:(BOOL)aForMove;
- (CGSRegionObj)_regionForOpaqueDescendants:(NSRect)aRect forMove:(BOOL)aForMove forUnderTitlebar:(BOOL)aForUnderTitlebar;
@end

@interface NSWindow(NSWindowShouldZoomOnDoubleClick)
+ (BOOL)_shouldZoomOnDoubleClick; // present on 10.7 and above
@end

// Starting with 10.7 the bottom corners of all windows are rounded.
// Unfortunately, the standard rounding that OS X applies to OpenGL views
// does not use anti-aliasing and looks very crude. Since we want a smooth,
// anti-aliased curve, we'll draw it ourselves.
// Additionally, we need to turn off the OS-supplied rounding because it
// eats into our corner's curve. We do that by overriding an NSSurface method.
@interface NSSurface @end

@implementation NSSurface(DontCutOffCorners)
- (CGSRegionObj)_createRoundedBottomRegionForRect:(CGRect)rect
{
  // Create a normal rect region without rounded bottom corners.
  CGSRegionObj region;
  CGSNewRegionWithRect(&rect, &region);
  return region;
}
@end

#pragma mark -

/* Convenience routine to go from a Goanna rect to Cocoa NSRect.
 *
 * Goanna rects (nsRect) contain an origin (x,y) in a coordinate
 * system with (0,0) in the top-left of the screen. Cocoa rects
 * (NSRect) contain an origin (x,y) in a coordinate system with
 * (0,0) in the bottom-left of the screen. Both nsRect and NSRect
 * contain width/height info, with no difference in their use.
 * If a Cocoa rect is from a flipped view, there is no need to
 * convert coordinate systems.
 */
#ifndef __LP64__
static inline void
ConvertGoannaRectToMacRect(const nsIntRect& aRect, Rect& outMacRect)
{
  outMacRect.left = aRect.x;
  outMacRect.top = aRect.y;
  outMacRect.right = aRect.x + aRect.width;
  outMacRect.bottom = aRect.y + aRect.height;
}
#endif

// Flips a screen coordinate from a point in the cocoa coordinate system (bottom-left rect) to a point
// that is a "flipped" cocoa coordinate system (starts in the top-left).
static inline void
FlipCocoaScreenCoordinate(NSPoint &inPoint)
{
  inPoint.y = nsCocoaUtils::FlippedScreenY(inPoint.y);
}

void EnsureLogInitialized()
{
#ifdef PR_LOGGING
  if (!sCocoaLog) {
    sCocoaLog = PR_NewLogModule("nsCocoaWidgets");
  }
#endif // PR_LOGGING
}

namespace {

// Manages a texture which can resize dynamically, binds to the
// LOCAL_GL_TEXTURE_RECTANGLE_ARB texture target and is automatically backed
// by a power-of-two size GL texture. The latter two features are used for
// compatibility with older Mac hardware which we block GL layers on.
// RectTextureImages are used both for accelerated GL layers drawing and for
// OMTC BasicLayers drawing.
class RectTextureImage {
public:
  explicit RectTextureImage(GLContext* aGLContext)
   : mGLContext(aGLContext)
   , mTexture(0)
   , mInUpdate(false)
  {}

  virtual ~RectTextureImage();

  TemporaryRef<gfx::DrawTarget>
    BeginUpdate(const nsIntSize& aNewSize,
                const nsIntRegion& aDirtyRegion = nsIntRegion());
  void EndUpdate(bool aKeepSurface = false);

  void UpdateIfNeeded(const nsIntSize& aNewSize,
                      const nsIntRegion& aDirtyRegion,
                      void (^aCallback)(gfx::DrawTarget*, const nsIntRegion&))
  {
    RefPtr<gfx::DrawTarget> drawTarget = BeginUpdate(aNewSize, aDirtyRegion);
    if (drawTarget) {
      aCallback(drawTarget, GetUpdateRegion());
      EndUpdate();
    }
  }

  void UpdateFromCGContext(const nsIntSize& aNewSize,
                           const nsIntRegion& aDirtyRegion,
                           CGContextRef aCGContext);

  void UpdateFromDrawTarget(const nsIntSize& aNewSize,
                            const nsIntRegion& aDirtyRegion,
                            gfx::DrawTarget* aFromDrawTarget);

  nsIntRegion GetUpdateRegion() {
    MOZ_ASSERT(mInUpdate, "update region only valid during update");
    return mUpdateRegion;
  }

  void Draw(mozilla::layers::GLManager* aManager,
            const nsIntPoint& aLocation,
            const Matrix4x4& aTransform = Matrix4x4());

  static nsIntSize TextureSizeForSize(const nsIntSize& aSize);

protected:

  RefPtr<gfx::DrawTarget> mUpdateDrawTarget;
  GLContext* mGLContext;
  nsIntRegion mUpdateRegion;
  nsIntSize mUsedSize;
  nsIntSize mBufferSize;
  nsIntSize mTextureSize;
  GLuint mTexture;
  bool mInUpdate;
};

// Used for OpenGL drawing from the compositor thread for OMTC BasicLayers.
// We need to use OpenGL for this because there seems to be no other robust
// way of drawing from a secondary thread without locking, which would cause
// deadlocks in our setup. See bug 882523.
class GLPresenter : public GLManager
{
public:
  static GLPresenter* CreateForWindow(nsIWidget* aWindow)
  {
    nsRefPtr<GLContext> context = gl::GLContextProvider::CreateForWindow(aWindow);
    return context ? new GLPresenter(context) : nullptr;
  }

  explicit GLPresenter(GLContext* aContext);
  virtual ~GLPresenter();

  virtual GLContext* gl() const override { return mGLContext; }
  virtual ShaderProgramOGL* GetProgram(GLenum aTarget, gfx::SurfaceFormat aFormat) override
  {
    MOZ_ASSERT(aTarget == LOCAL_GL_TEXTURE_RECTANGLE_ARB);
    MOZ_ASSERT(aFormat == gfx::SurfaceFormat::R8G8B8A8);
    return mRGBARectProgram;
  }
  virtual const gfx::Matrix4x4& GetProjMatrix() const override
  {
    return mProjMatrix;
  }
  virtual void ActivateProgram(ShaderProgramOGL *aProg) override
  {
    mGLContext->fUseProgram(aProg->GetProgram());
  }
  virtual void BindAndDrawQuad(ShaderProgramOGL *aProg,
                               const gfx::Rect& aLayerRect,
                               const gfx::Rect& aTextureRect) override;

  void BeginFrame(nsIntSize aRenderSize);
  void EndFrame();

  NSOpenGLContext* GetNSOpenGLContext()
  {
    return GLContextCGL::Cast(mGLContext)->GetNSOpenGLContext();
  }

protected:
  nsRefPtr<mozilla::gl::GLContext> mGLContext;
  nsAutoPtr<mozilla::layers::ShaderProgramOGL> mRGBARectProgram;
  gfx::Matrix4x4 mProjMatrix;
  GLuint mQuadVBO;
};

} // unnamed namespace

#pragma mark -

nsChildView::nsChildView() : nsBaseWidget()
, mView(nullptr)
, mParentView(nullptr)
, mParentWidget(nullptr)
, mViewTearDownLock("ChildViewTearDown")
, mEffectsLock("WidgetEffects")
, mShowsResizeIndicator(false)
, mHasRoundedBottomCorners(false)
, mIsCoveringTitlebar(false)
, mIsFullscreen(false)
, mTitlebarCGContext(nullptr)
, mBackingScaleFactor(0.0)
, mVisible(false)
, mDrawing(false)
, mIsDispatchPaint(false)
{
  EnsureLogInitialized();
}

nsChildView::~nsChildView()
{
  ReleaseTitlebarCGContext();

  // Notify the children that we're gone.  childView->ResetParent() can change
  // our list of children while it's being iterated, so the way we iterate the
  // list must allow for this.
  for (nsIWidget* kid = mLastChild; kid;) {
    nsChildView* childView = static_cast<nsChildView*>(kid);
    kid = kid->GetPrevSibling();
    childView->ResetParent();
  }

  NS_WARN_IF_FALSE(mOnDestroyCalled, "nsChildView object destroyed without calling Destroy()");

  DestroyCompositor();

  if (mAPZC) {
    gNumberOfWidgetsNeedingEventThread--;
    if (gNumberOfWidgetsNeedingEventThread == 0) {
      [EventThreadRunner stop];
    }
  }

  // An nsChildView object that was in use can be destroyed without Destroy()
  // ever being called on it.  So we also need to do a quick, safe cleanup
  // here (it's too late to just call Destroy(), which can cause crashes).
  // It's particularly important to make sure widgetDestroyed is called on our
  // mView -- this method NULLs mView's mGoannaChild, and NULL checks on
  // mGoannaChild are used throughout the ChildView class to tell if it's safe
  // to use a ChildView object.
  [mView widgetDestroyed]; // Safe if mView is nil.
  mParentWidget = nil;
  TearDownView(); // Safe if called twice.
}

void
nsChildView::ReleaseTitlebarCGContext()
{
  if (mTitlebarCGContext) {
    CGContextRelease(mTitlebarCGContext);
    mTitlebarCGContext = nullptr;
  }
}

nsresult nsChildView::Create(nsIWidget *aParent,
                             nsNativeWidget aNativeParent,
                             const nsIntRect &aRect,
                             nsWidgetInitData *aInitData)
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_NSRESULT;

  // Because the hidden window is created outside of an event loop,
  // we need to provide an autorelease pool to avoid leaking cocoa objects
  // (see bug 559075).
  nsAutoreleasePool localPool;

  // See NSView (MethodSwizzling) below.
  if (!gChildViewMethodsSwizzled) {
    nsToolkit::SwizzleMethods([NSView class], @selector(mouseDownCanMoveWindow),
                              @selector(nsChildView_NSView_mouseDownCanMoveWindow));
#ifdef __LP64__
    if (nsCocoaFeatures::OnLionOrLater()) {
      nsToolkit::SwizzleMethods([NSEvent class], @selector(addLocalMonitorForEventsMatchingMask:handler:),
                                @selector(nsChildView_NSEvent_addLocalMonitorForEventsMatchingMask:handler:),
                                true);
      nsToolkit::SwizzleMethods([NSEvent class], @selector(removeMonitor:),
                                @selector(nsChildView_NSEvent_removeMonitor:), true);
    }
#endif
    gChildViewMethodsSwizzled = true;
  }

  mBounds = aRect;

  // Ensure that the toolkit is created.
  nsToolkit::GetToolkit();

  BaseCreate(aParent, aRect, aInitData);

  // inherit things from the parent view and create our parallel
  // NSView in the Cocoa display system
  mParentView = nil;
  if (aParent) {
    // inherit the top-level window. NS_NATIVE_WIDGET is always a NSView
    // regardless of if we're asking a window or a view (for compatibility
    // with windows).
    mParentView = (NSView<mozView>*)aParent->GetNativeData(NS_NATIVE_WIDGET);
    mParentWidget = aParent;
  } else {
    // This is the normal case. When we're the root widget of the view hiararchy,
    // aNativeParent will be the contentView of our window, since that's what
    // nsCocoaWindow returns when asked for an NS_NATIVE_VIEW.
    mParentView = reinterpret_cast<NSView<mozView>*>(aNativeParent);
  }

  // create our parallel NSView and hook it up to our parent. Recall
  // that NS_NATIVE_WIDGET is the NSView.
  CGFloat scaleFactor = nsCocoaUtils::GetBackingScaleFactor(mParentView);
  NSRect r = nsCocoaUtils::DevPixelsToCocoaPoints(mBounds, scaleFactor);
  mView = [(NSView<mozView>*)CreateCocoaView(r) retain];
  if (!mView) {
    return NS_ERROR_FAILURE;
  }

  // If this view was created in a Goanna view hierarchy, the initial state
  // is hidden.  If the view is attached only to a native NSView but has
  // no Goanna parent (as in embedding), the initial state is visible.
  if (mParentWidget)
    [mView setHidden:YES];
  else
    mVisible = true;

  // Hook it up in the NSView hierarchy.
  if (mParentView) {
    [mParentView addSubview:mView];
  }

  // if this is a ChildView, make sure that our per-window data
  // is set up
  if ([mView isKindOfClass:[ChildView class]])
    [[WindowDataMap sharedWindowDataMap] ensureDataForWindow:[mView window]];

  NS_ASSERTION(!mTextInputHandler, "mTextInputHandler has already existed");
  mTextInputHandler = new TextInputHandler(this, mView);

  mPluginFocused = false;

  return NS_OK;

  NS_OBJC_END_TRY_ABORT_BLOCK_NSRESULT;
}

// Creates the appropriate child view. Override to create something other than
// our |ChildView| object. Autoreleases, so caller must retain.
NSView*
nsChildView::CreateCocoaView(NSRect inFrame)
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_NIL;

  return [[[ChildView alloc] initWithFrame:inFrame goannaChild:this] autorelease];

  NS_OBJC_END_TRY_ABORT_BLOCK_NIL;
}

void nsChildView::TearDownView()
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK;

  if (!mView)
    return;

  NSWindow* win = [mView window];
  NSResponder* responder = [win firstResponder];

  // We're being unhooked from the view hierarchy, don't leave our view
  // or a child view as the window first responder.
  if (responder && [responder isKindOfClass:[NSView class]] &&
      [(NSView*)responder isDescendantOf:mView]) {
    [win makeFirstResponder:[mView superview]];
  }

  // If mView is win's contentView, win (mView's NSWindow) "owns" mView --
  // win has retained mView, and will detach it from the view hierarchy and
  // release it when necessary (when win is itself destroyed (in a call to
  // [win dealloc])).  So all we need to do here is call [mView release] (to
  // match the call to [mView retain] in nsChildView::StandardCreate()).
  // Also calling [mView removeFromSuperviewWithoutNeedingDisplay] causes
  // mView to be released again and dealloced, while remaining win's
  // contentView.  So if we do that here, win will (for a short while) have
  // an invalid contentView (for the consequences see bmo bugs 381087 and
  // 374260).
  if ([mView isEqual:[win contentView]]) {
    [mView release];
  } else {
    // Stop NSView hierarchy being changed during [ChildView drawRect:]
    [mView performSelectorOnMainThread:@selector(delayedTearDown) withObject:nil waitUntilDone:false];
  }
  mView = nil;

  NS_OBJC_END_TRY_ABORT_BLOCK;
}

nsCocoaWindow*
nsChildView::GetXULWindowWidget()
{
  id windowDelegate = [[mView window] delegate];
  if (windowDelegate && [windowDelegate isKindOfClass:[WindowDelegate class]]) {
    return [(WindowDelegate *)windowDelegate goannaWidget];
  }
  return nullptr;
}

NS_IMETHODIMP nsChildView::Destroy()
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_NSRESULT;

  // Make sure that no composition is in progress while disconnecting
  // ourselves from the view.
  MutexAutoLock lock(mViewTearDownLock);

  if (mOnDestroyCalled)
    return NS_OK;
  mOnDestroyCalled = true;

  [mView widgetDestroyed];

  nsBaseWidget::Destroy();

  NotifyWindowDestroyed();
  mParentWidget = nil;

  TearDownView();

  nsBaseWidget::OnDestroy();

  return NS_OK;

  NS_OBJC_END_TRY_ABORT_BLOCK_NSRESULT;
}

#pragma mark -

#if 0
static void PrintViewHierarchy(NSView *view)
{
  while (view) {
    NSLog(@"  view is %x, frame %@", view, NSStringFromRect([view frame]));
    view = [view superview];
  }
}
#endif

// Return native data according to aDataType
void* nsChildView::GetNativeData(uint32_t aDataType)
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_NSNULL;

  void* retVal = nullptr;

  switch (aDataType)
  {
    case NS_NATIVE_WIDGET:
    case NS_NATIVE_DISPLAY:
      retVal = (void*)mView;
      break;

    case NS_NATIVE_WINDOW:
      retVal = [mView window];
      break;

    case NS_NATIVE_GRAPHIC:
      NS_ERROR("Requesting NS_NATIVE_GRAPHIC on a Mac OS X child view!");
      retVal = nullptr;
      break;

    case NS_NATIVE_OFFSETX:
      retVal = 0;
      break;

    case NS_NATIVE_OFFSETY:
      retVal = 0;
      break;
  }

  return retVal;

  NS_OBJC_END_TRY_ABORT_BLOCK_NSNULL;
}

#pragma mark -

nsTransparencyMode nsChildView::GetTransparencyMode()
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_RETURN;

  nsCocoaWindow* windowWidget = GetXULWindowWidget();
  return windowWidget ? windowWidget->GetTransparencyMode() : eTransparencyOpaque;

  NS_OBJC_END_TRY_ABORT_BLOCK_RETURN(eTransparencyOpaque);
}

// This is called by nsContainerFrame on the root widget for all window types
// except popup windows (when nsCocoaWindow::SetTransparencyMode is used instead).
void nsChildView::SetTransparencyMode(nsTransparencyMode aMode)
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK;

  nsCocoaWindow* windowWidget = GetXULWindowWidget();
  if (windowWidget) {
    windowWidget->SetTransparencyMode(aMode);
  }

  NS_OBJC_END_TRY_ABORT_BLOCK;
}

bool nsChildView::IsVisible() const
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_RETURN;

  if (!mVisible) {
    return mVisible;
  }

  // mVisible does not accurately reflect the state of a hidden tabbed view
  // so verify that the view has a window as well
  // then check native widget hierarchy visibility
  return ([mView window] != nil) && !NSIsEmptyRect([mView visibleRect]);

  NS_OBJC_END_TRY_ABORT_BLOCK_RETURN(false);
}

// Some NSView methods (e.g. setFrame and setHidden) invalidate the view's
// bounds in our window. However, we don't want these invalidations because
// they are unnecessary and because they actually slow us down since we
// block on the compositor inside drawRect.
// When we actually need something invalidated, there will be an explicit call
// to Invalidate from Goanna, so turning these automatic invalidations off
// won't hurt us in the non-OMTC case.
// The invalidations inside these NSView methods happen via a call to the
// private method -[NSWindow _setNeedsDisplayInRect:]. Our BaseWindow
// implementation of that method is augmented to let us ignore those calls
// using -[BaseWindow disable/enableSetNeedsDisplay].
static void
ManipulateViewWithoutNeedingDisplay(NSView* aView, void (^aCallback)())
{
  BaseWindow* win = nil;
  if ([[aView window] isKindOfClass:[BaseWindow class]]) {
    win = (BaseWindow*)[aView window];
  }
  [win disableSetNeedsDisplay];
  aCallback();
  [win enableSetNeedsDisplay];
}

// Hide or show this component
NS_IMETHODIMP nsChildView::Show(bool aState)
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_NSRESULT;

  if (aState != mVisible) {
    // Provide an autorelease pool because this gets called during startup
    // on the "hidden window", resulting in cocoa object leakage if there's
    // no pool in place.
    nsAutoreleasePool localPool;

    ManipulateViewWithoutNeedingDisplay(mView, ^{
      [mView setHidden:!aState];
    });

    mVisible = aState;
  }
  return NS_OK;

  NS_OBJC_END_TRY_ABORT_BLOCK_NSRESULT;
}

// Change the parent of this widget
NS_IMETHODIMP
nsChildView::SetParent(nsIWidget* aNewParent)
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_NSRESULT;

  if (mOnDestroyCalled)
    return NS_OK;

  nsCOMPtr<nsIWidget> kungFuDeathGrip(this);

  if (mParentWidget) {
    mParentWidget->RemoveChild(this);
  }

  if (aNewParent) {
    ReparentNativeWidget(aNewParent);
  } else {
    [mView removeFromSuperview];
    mParentView = nil;
  }

  mParentWidget = aNewParent;

  if (mParentWidget) {
    mParentWidget->AddChild(this);
  }

  return NS_OK;

  NS_OBJC_END_TRY_ABORT_BLOCK_NSRESULT;
}

NS_IMETHODIMP
nsChildView::ReparentNativeWidget(nsIWidget* aNewParent)
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_NSRESULT;

  NS_PRECONDITION(aNewParent, "");

  if (mOnDestroyCalled)
    return NS_OK;

  NSView<mozView>* newParentView =
   (NSView<mozView>*)aNewParent->GetNativeData(NS_NATIVE_WIDGET);
  NS_ENSURE_TRUE(newParentView, NS_ERROR_FAILURE);

  // we hold a ref to mView, so this is safe
  [mView removeFromSuperview];
  mParentView = newParentView;
  [mParentView addSubview:mView];
  return NS_OK;

  NS_OBJC_END_TRY_ABORT_BLOCK_NSRESULT;
}

void nsChildView::ResetParent()
{
  if (!mOnDestroyCalled) {
    if (mParentWidget)
      mParentWidget->RemoveChild(this);
    if (mView)
      [mView removeFromSuperview];
  }
  mParentWidget = nullptr;
}

nsIWidget*
nsChildView::GetParent()
{
  return mParentWidget;
}

float
nsChildView::GetDPI()
{
  NSWindow* window = [mView window];
  if (window && [window isKindOfClass:[BaseWindow class]]) {
    return [(BaseWindow*)window getDPI];
  }

  return 96.0;
}

NS_IMETHODIMP nsChildView::Enable(bool aState)
{
  return NS_OK;
}

bool nsChildView::IsEnabled() const
{
  return true;
}

NS_IMETHODIMP nsChildView::SetFocus(bool aRaise)
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_NSRESULT;

  NSWindow* window = [mView window];
  if (window)
    [window makeFirstResponder:mView];
  return NS_OK;

  NS_OBJC_END_TRY_ABORT_BLOCK_NSRESULT;
}

// Override to set the cursor on the mac
NS_IMETHODIMP nsChildView::SetCursor(nsCursor aCursor)
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_NSRESULT;

  if ([mView isDragInProgress])
    return NS_OK; // Don't change the cursor during dragging.

  nsBaseWidget::SetCursor(aCursor);
  return [[nsCursorManager sharedInstance] setCursor:aCursor];

  NS_OBJC_END_TRY_ABORT_BLOCK_NSRESULT;
}

// implement to fix "hidden virtual function" warning
NS_IMETHODIMP nsChildView::SetCursor(imgIContainer* aCursor,
                                      uint32_t aHotspotX, uint32_t aHotspotY)
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_NSRESULT;

  nsBaseWidget::SetCursor(aCursor, aHotspotX, aHotspotY);
  return [[nsCursorManager sharedInstance] setCursorWithImage:aCursor hotSpotX:aHotspotX hotSpotY:aHotspotY scaleFactor:BackingScaleFactor()];

  NS_OBJC_END_TRY_ABORT_BLOCK_NSRESULT;
}

#pragma mark -

// Get this component dimension
NS_IMETHODIMP nsChildView::GetBounds(nsIntRect &aRect)
{
  if (!mView) {
    aRect = mBounds;
  } else {
    aRect = CocoaPointsToDevPixels([mView frame]);
  }
  return NS_OK;
}

NS_IMETHODIMP nsChildView::GetClientBounds(nsIntRect &aRect)
{
  GetBounds(aRect);
  if (!mParentWidget) {
    // For top level widgets we want the position on screen, not the position
    // of this view inside the window.
    aRect.MoveTo(WidgetToScreenOffsetUntyped());
  }
  return NS_OK;
}

NS_IMETHODIMP nsChildView::GetScreenBounds(nsIntRect &aRect)
{
  GetBounds(aRect);
  aRect.MoveTo(WidgetToScreenOffsetUntyped());
  return NS_OK;
}

double
nsChildView::GetDefaultScaleInternal()
{
  return BackingScaleFactor();
}

CGFloat
nsChildView::BackingScaleFactor() const
{
  if (mBackingScaleFactor > 0.0) {
    return mBackingScaleFactor;
  }
  if (!mView) {
    return 1.0;
  }
  mBackingScaleFactor = nsCocoaUtils::GetBackingScaleFactor(mView);
  return mBackingScaleFactor;
}

void
nsChildView::BackingScaleFactorChanged()
{
  CGFloat newScale = nsCocoaUtils::GetBackingScaleFactor(mView);

  // ignore notification if it hasn't really changed (or maybe we have
  // disabled HiDPI mode via prefs)
  if (mBackingScaleFactor == newScale) {
    return;
  }

  mBackingScaleFactor = newScale;

  if (mWidgetListener && !mWidgetListener->GetXULWindow()) {
    nsIPresShell* presShell = mWidgetListener->GetPresShell();
    if (presShell) {
      presShell->BackingScaleFactorChanged();
    }
  }
}

int32_t
nsChildView::RoundsWidgetCoordinatesTo()
{
  if (BackingScaleFactor() == 2.0) {
    return 2;
  }
  return 1;
}

NS_IMETHODIMP nsChildView::ConstrainPosition(bool aAllowSlop,
                                             int32_t *aX, int32_t *aY)
{
  return NS_OK;
}

// Move this component, aX and aY are in the parent widget coordinate system
NS_IMETHODIMP nsChildView::Move(double aX, double aY)
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_NSRESULT;

  int32_t x = NSToIntRound(aX);
  int32_t y = NSToIntRound(aY);

  if (!mView || (mBounds.x == x && mBounds.y == y))
    return NS_OK;

  mBounds.x = x;
  mBounds.y = y;

  ManipulateViewWithoutNeedingDisplay(mView, ^{
    [mView setFrame:DevPixelsToCocoaPoints(mBounds)];
  });

  NotifyRollupGeometryChange();
  ReportMoveEvent();

  return NS_OK;

  NS_OBJC_END_TRY_ABORT_BLOCK_NSRESULT;
}

NS_IMETHODIMP nsChildView::Resize(double aWidth, double aHeight, bool aRepaint)
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_NSRESULT;

  int32_t width = NSToIntRound(aWidth);
  int32_t height = NSToIntRound(aHeight);

  if (!mView || (mBounds.width == width && mBounds.height == height))
    return NS_OK;

  mBounds.width  = width;
  mBounds.height = height;

  ManipulateViewWithoutNeedingDisplay(mView, ^{
    [mView setFrame:DevPixelsToCocoaPoints(mBounds)];
  });

  if (mVisible && aRepaint)
    [mView setNeedsDisplay:YES];

  NotifyRollupGeometryChange();
  ReportSizeEvent();

  return NS_OK;

  NS_OBJC_END_TRY_ABORT_BLOCK_NSRESULT;
}

NS_IMETHODIMP nsChildView::Resize(double aX, double aY,
                                  double aWidth, double aHeight, bool aRepaint)
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_NSRESULT;

  int32_t x = NSToIntRound(aX);
  int32_t y = NSToIntRound(aY);
  int32_t width = NSToIntRound(aWidth);
  int32_t height = NSToIntRound(aHeight);

  BOOL isMoving = (mBounds.x != x || mBounds.y != y);
  BOOL isResizing = (mBounds.width != width || mBounds.height != height);
  if (!mView || (!isMoving && !isResizing))
    return NS_OK;

  if (isMoving) {
    mBounds.x = x;
    mBounds.y = y;
  }
  if (isResizing) {
    mBounds.width  = width;
    mBounds.height = height;
  }

  ManipulateViewWithoutNeedingDisplay(mView, ^{
    [mView setFrame:DevPixelsToCocoaPoints(mBounds)];
  });

  if (mVisible && aRepaint)
    [mView setNeedsDisplay:YES];

  NotifyRollupGeometryChange();
  if (isMoving) {
    ReportMoveEvent();
    if (mOnDestroyCalled)
      return NS_OK;
  }
  if (isResizing)
    ReportSizeEvent();

  return NS_OK;

  NS_OBJC_END_TRY_ABORT_BLOCK_NSRESULT;
}

static const int32_t resizeIndicatorWidth = 15;
static const int32_t resizeIndicatorHeight = 15;
bool nsChildView::ShowsResizeIndicator(nsIntRect* aResizerRect)
{
  NSView *topLevelView = mView, *superView = nil;
  while ((superView = [topLevelView superview]))
    topLevelView = superView;

  if (![[topLevelView window] showsResizeIndicator] ||
      !([[topLevelView window] styleMask] & NSResizableWindowMask))
    return false;

  if (aResizerRect) {
    NSSize bounds = [topLevelView bounds].size;
    NSPoint corner = NSMakePoint(bounds.width, [topLevelView isFlipped] ? bounds.height : 0);
    corner = [topLevelView convertPoint:corner toView:mView];
    aResizerRect->SetRect(NSToIntRound(corner.x) - resizeIndicatorWidth,
                          NSToIntRound(corner.y) - resizeIndicatorHeight,
                          resizeIndicatorWidth, resizeIndicatorHeight);
  }
  return true;
}

nsresult nsChildView::SynthesizeNativeKeyEvent(int32_t aNativeKeyboardLayout,
                                               int32_t aNativeKeyCode,
                                               uint32_t aModifierFlags,
                                               const nsAString& aCharacters,
                                               const nsAString& aUnmodifiedCharacters)
{
  return mTextInputHandler->SynthesizeNativeKeyEvent(aNativeKeyboardLayout,
                                                     aNativeKeyCode,
                                                     aModifierFlags,
                                                     aCharacters,
                                                     aUnmodifiedCharacters);
}

nsresult nsChildView::SynthesizeNativeMouseEvent(LayoutDeviceIntPoint aPoint,
                                                 uint32_t aNativeMessage,
                                                 uint32_t aModifierFlags)
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_NSRESULT;

  NSPoint pt =
    nsCocoaUtils::DevPixelsToCocoaPoints(aPoint, BackingScaleFactor());

  // Move the mouse cursor to the requested position and reconnect it to the mouse.
  CGWarpMouseCursorPosition(NSPointToCGPoint(pt));
  CGAssociateMouseAndMouseCursorPosition(true);

  // aPoint is given with the origin on the top left, but convertScreenToBase
  // expects a point in a coordinate system that has its origin on the bottom left.
  NSPoint screenPoint = NSMakePoint(pt.x, nsCocoaUtils::FlippedScreenY(pt.y));
  NSPoint windowPoint = [[mView window] convertScreenToBase:screenPoint];

  NSEvent* event = [NSEvent mouseEventWithType:(NSEventType)aNativeMessage
                                      location:windowPoint
                                 modifierFlags:aModifierFlags
                                     timestamp:[NSDate timeIntervalSinceReferenceDate]
                                  windowNumber:[[mView window] windowNumber]
                                       context:nil
                                   eventNumber:0
                                    clickCount:1
                                      pressure:0.0];

  if (!event)
    return NS_ERROR_FAILURE;

  if ([[mView window] isKindOfClass:[BaseWindow class]]) {
    // Tracking area events don't end up in their tracking areas when sent
    // through [NSApp sendEvent:], so pass them directly to the right methods.
    BaseWindow* window = (BaseWindow*)[mView window];
    if (aNativeMessage == NSMouseEntered) {
      [window mouseEntered:event];
      return NS_OK;
    }
    if (aNativeMessage == NSMouseExited) {
      [window mouseExited:event];
      return NS_OK;
    }
    if (aNativeMessage == NSMouseMoved) {
      [window mouseMoved:event];
      return NS_OK;
    }
  }

  [NSApp sendEvent:event];
  return NS_OK;

  NS_OBJC_END_TRY_ABORT_BLOCK_NSRESULT;
}

// First argument has to be an NSMenu representing the application's top-level
// menu bar. The returned item is *not* retained.
static NSMenuItem* NativeMenuItemWithLocation(NSMenu* menubar, NSString* locationString)
{
  NSArray* indexes = [locationString componentsSeparatedByString:@"|"];
  unsigned int indexCount = [indexes count];
  if (indexCount == 0)
    return nil;

  NSMenu* currentSubmenu = [NSApp mainMenu];
  for (unsigned int i = 0; i < indexCount; i++) {
    int targetIndex;
    // We remove the application menu from consideration for the top-level menu
    if (i == 0)
      targetIndex = [[indexes objectAtIndex:i] intValue] + 1;
    else
      targetIndex = [[indexes objectAtIndex:i] intValue];
    int itemCount = [currentSubmenu numberOfItems];
    if (targetIndex < itemCount) {
      NSMenuItem* menuItem = [currentSubmenu itemAtIndex:targetIndex];
      // if this is the last index just return the menu item
      if (i == (indexCount - 1))
        return menuItem;
      // if this is not the last index find the submenu and keep going
      if ([menuItem hasSubmenu])
        currentSubmenu = [menuItem submenu];
      else
        return nil;
    }
  }

  return nil;
}

// Used for testing native menu system structure and event handling.
NS_IMETHODIMP nsChildView::ActivateNativeMenuItemAt(const nsAString& indexString)
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_NSRESULT;

  NSString* locationString = [NSString stringWithCharacters:reinterpret_cast<const unichar*>(indexString.BeginReading())
                                                     length:indexString.Length()];
  NSMenuItem* item = NativeMenuItemWithLocation([NSApp mainMenu], locationString);
  // We can't perform an action on an item with a submenu, that will raise
  // an obj-c exception.
  if (item && ![item hasSubmenu]) {
    NSMenu* parent = [item menu];
    if (parent) {
      // NSLog(@"Performing action for native menu item titled: %@\n",
      //       [[currentSubmenu itemAtIndex:targetIndex] title]);
      [parent performActionForItemAtIndex:[parent indexOfItem:item]];
      return NS_OK;
    }
  }
  return NS_ERROR_FAILURE;

  NS_OBJC_END_TRY_ABORT_BLOCK_NSRESULT;
}

// Used for testing native menu system structure and event handling.
NS_IMETHODIMP nsChildView::ForceUpdateNativeMenuAt(const nsAString& indexString)
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_NSRESULT;

  nsCocoaWindow *widget = GetXULWindowWidget();
  if (widget) {
    nsMenuBarX* mb = widget->GetMenuBar();
    if (mb) {
      if (indexString.IsEmpty())
        mb->ForceNativeMenuReload();
      else
        mb->ForceUpdateNativeMenuAt(indexString);
    }
  }
  return NS_OK;

  NS_OBJC_END_TRY_ABORT_BLOCK_NSRESULT;
}

#pragma mark -

#ifdef INVALIDATE_DEBUGGING

static Boolean KeyDown(const UInt8 theKey)
{
  KeyMap map;
  GetKeys(map);
  return ((*((UInt8 *)map + (theKey >> 3)) >> (theKey & 7)) & 1) != 0;
}

static Boolean caps_lock()
{
  return KeyDown(0x39);
}

static void blinkRect(Rect* r)
{
  StRegionFromPool oldClip;
  if (oldClip != NULL)
    ::GetClip(oldClip);

  ::ClipRect(r);
  ::InvertRect(r);
  UInt32 end = ::TickCount() + 5;
  while (::TickCount() < end) ;
  ::InvertRect(r);

  if (oldClip != NULL)
    ::SetClip(oldClip);
}

static void blinkRgn(RgnHandle rgn)
{
  StRegionFromPool oldClip;
  if (oldClip != NULL)
    ::GetClip(oldClip);

  ::SetClip(rgn);
  ::InvertRgn(rgn);
  UInt32 end = ::TickCount() + 5;
  while (::TickCount() < end) ;
  ::InvertRgn(rgn);

  if (oldClip != NULL)
    ::SetClip(oldClip);
}

#endif

// Invalidate this component's visible area
NS_IMETHODIMP nsChildView::Invalidate(const nsIntRect &aRect)
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_NSRESULT;

  if (!mView || !mVisible)
    return NS_OK;

  NS_ASSERTION(GetLayerManager()->GetBackendType() != LayersBackend::LAYERS_CLIENT,
               "Shouldn't need to invalidate with accelerated OMTC layers!");

  if ([NSView focusView]) {
    // if a view is focussed (i.e. being drawn), then postpone the invalidate so that we
    // don't lose it.
    [mView setNeedsPendingDisplayInRect:DevPixelsToCocoaPoints(aRect)];
  }
  else {
    [mView setNeedsDisplayInRect:DevPixelsToCocoaPoints(aRect)];
  }

  return NS_OK;

  NS_OBJC_END_TRY_ABORT_BLOCK_NSRESULT;
}

bool
nsChildView::ComputeShouldAccelerate(bool aDefault)
{
  // Don't use OpenGL for transparent windows or for popup windows.
  if (!mView || ![[mView window] isOpaque] ||
      [[mView window] isKindOfClass:[PopupWindow class]])
    return false;

  return nsBaseWidget::ComputeShouldAccelerate(aDefault);
}

bool
nsChildView::ShouldUseOffMainThreadCompositing()
{
  // Don't use OMTC for transparent windows or for popup windows.
  if (!mView || ![[mView window] isOpaque] ||
      [[mView window] isKindOfClass:[PopupWindow class]])
    return false;

  return nsBaseWidget::ShouldUseOffMainThreadCompositing();
}

inline uint16_t COLOR8TOCOLOR16(uint8_t color8)
{
  // return (color8 == 0xFF ? 0xFFFF : (color8 << 8));
  return (color8 << 8) | color8;  /* (color8 * 257) == (color8 * 0x0101) */
}

#pragma mark -

nsresult nsChildView::ConfigureChildren(const nsTArray<Configuration>& aConfigurations)
{
  return NS_OK;
}

// Invokes callback and ProcessEvent methods on Event Listener object
NS_IMETHODIMP nsChildView::DispatchEvent(WidgetGUIEvent* event,
                                         nsEventStatus& aStatus)
{
#ifdef DEBUG
  debug_DumpEvent(stdout, event->widget, event, nsAutoCString("something"), 0);
#endif

  NS_ASSERTION(!(mTextInputHandler && mTextInputHandler->IsIMEComposing() &&
                 event->HasKeyEventMessage()),
    "Any key events should not be fired during IME composing");

  if (event->mFlags.mIsSynthesizedForTests) {
    WidgetKeyboardEvent* keyEvent = event->AsKeyboardEvent();
    if (keyEvent) {
      nsresult rv = mTextInputHandler->AttachNativeKeyEvent(*keyEvent);
      NS_ENSURE_SUCCESS(rv, rv);
    }
  }

  aStatus = nsEventStatus_eIgnore;

  nsIWidgetListener* listener = mWidgetListener;

  // If the listener is NULL, check if the parent is a popup. If it is, then
  // this child is the popup content view attached to a popup. Get the
  // listener from the parent popup instead.
  nsCOMPtr<nsIWidget> kungFuDeathGrip = do_QueryInterface(mParentWidget ? mParentWidget : this);
  if (!listener && mParentWidget) {
    if (mParentWidget->WindowType() == eWindowType_popup) {
      // Check just in case event->widget isn't this widget
      if (event->widget)
        listener = event->widget->GetWidgetListener();
      if (!listener) {
        event->widget = mParentWidget;
        listener = mParentWidget->GetWidgetListener();
      }
    }
  }

  if (listener)
    aStatus = listener->HandleEvent(event, mUseAttachedEvents);

  return NS_OK;
}

bool nsChildView::DispatchWindowEvent(WidgetGUIEvent& event)
{
  nsEventStatus status;
  DispatchEvent(&event, status);
  return ConvertStatus(status);
}

nsIWidget*
nsChildView::GetWidgetForListenerEvents()
{
  // If there is no listener, use the parent popup's listener if that exists.
  if (!mWidgetListener && mParentWidget &&
      mParentWidget->WindowType() == eWindowType_popup) {
    return mParentWidget;
  }

  return this;
}

void nsChildView::WillPaintWindow()
{
  nsCOMPtr<nsIWidget> widget = GetWidgetForListenerEvents();

  nsIWidgetListener* listener = widget->GetWidgetListener();
  if (listener) {
    listener->WillPaintWindow(widget);
  }
}

bool nsChildView::PaintWindow(nsIntRegion aRegion)
{
  nsCOMPtr<nsIWidget> widget = GetWidgetForListenerEvents();

  nsIWidgetListener* listener = widget->GetWidgetListener();
  if (!listener)
    return false;

  bool returnValue = false;
  bool oldDispatchPaint = mIsDispatchPaint;
  mIsDispatchPaint = true;
  returnValue = listener->PaintWindow(widget, aRegion);

  listener = widget->GetWidgetListener();
  if (listener) {
    listener->DidPaintWindow();
  }

  mIsDispatchPaint = oldDispatchPaint;
  return returnValue;
}

#pragma mark -

void nsChildView::ReportMoveEvent()
{
   NotifyWindowMoved(mBounds.x, mBounds.y);
}

void nsChildView::ReportSizeEvent()
{
  if (mWidgetListener)
    mWidgetListener->WindowResized(this, mBounds.width, mBounds.height);
}

#pragma mark -

//    Return the offset between this child view and the screen.
//    @return       -- widget origin in device-pixel coords
LayoutDeviceIntPoint nsChildView::WidgetToScreenOffset()
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_RETURN;

  NSPoint origin = NSMakePoint(0, 0);

  // 1. First translate view origin point into window coords.
  // The returned point is in bottom-left coordinates.
  origin = [mView convertPoint:origin toView:nil];

  // 2. We turn the window-coord rect's origin into screen (still bottom-left) coords.
  origin = [[mView window] convertBaseToScreen:origin];

  // 3. Since we're dealing in bottom-left coords, we need to make it top-left coords
  //    before we pass it back to Goanna.
  FlipCocoaScreenCoordinate(origin);

  // convert to device pixels
  return LayoutDeviceIntPoint::FromUntyped(CocoaPointsToDevPixels(origin));

  NS_OBJC_END_TRY_ABORT_BLOCK_RETURN(LayoutDeviceIntPoint(0,0));
}

NS_IMETHODIMP nsChildView::CaptureRollupEvents(nsIRollupListener * aListener,
                                               bool aDoCapture)
{
  // this never gets called, only top-level windows can be rollup widgets
  return NS_OK;
}

NS_IMETHODIMP nsChildView::SetTitle(const nsAString& title)
{
  // child views don't have titles
  return NS_OK;
}

NS_IMETHODIMP nsChildView::GetAttention(int32_t aCycleCount)
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_NSRESULT;

  [NSApp requestUserAttention:NSInformationalRequest];
  return NS_OK;

  NS_OBJC_END_TRY_ABORT_BLOCK_NSRESULT;
}

/* static */
bool nsChildView::DoHasPendingInputEvent()
{
  return sLastInputEventCount != GetCurrentInputEventCount();
}

/* static */
uint32_t nsChildView::GetCurrentInputEventCount()
{
  // Can't use kCGAnyInputEventType because that updates too rarely for us (and
  // always in increments of 30+!) and because apparently it's sort of broken
  // on Tiger.  So just go ahead and query the counters we care about.
  static const CGEventType eventTypes[] = {
    kCGEventLeftMouseDown,
    kCGEventLeftMouseUp,
    kCGEventRightMouseDown,
    kCGEventRightMouseUp,
    kCGEventMouseMoved,
    kCGEventLeftMouseDragged,
    kCGEventRightMouseDragged,
    kCGEventKeyDown,
    kCGEventKeyUp,
    kCGEventScrollWheel,
    kCGEventTabletPointer,
    kCGEventOtherMouseDown,
    kCGEventOtherMouseUp,
    kCGEventOtherMouseDragged
  };

  uint32_t eventCount = 0;
  for (uint32_t i = 0; i < ArrayLength(eventTypes); ++i) {
    eventCount +=
      CGEventSourceCounterForEventType(kCGEventSourceStateCombinedSessionState,
                                       eventTypes[i]);
  }
  return eventCount;
}

/* static */
void nsChildView::UpdateCurrentInputEventCount()
{
  sLastInputEventCount = GetCurrentInputEventCount();
}

bool nsChildView::HasPendingInputEvent()
{
  return DoHasPendingInputEvent();
}

#pragma mark -

nsresult
nsChildView::NotifyIMEInternal(const IMENotification& aIMENotification)
{
  switch (aIMENotification.mMessage) {
    case REQUEST_TO_COMMIT_COMPOSITION:
      NS_ENSURE_TRUE(mTextInputHandler, NS_ERROR_NOT_AVAILABLE);
      mTextInputHandler->CommitIMEComposition();
      return NS_OK;
    case REQUEST_TO_CANCEL_COMPOSITION:
      NS_ENSURE_TRUE(mTextInputHandler, NS_ERROR_NOT_AVAILABLE);
      mTextInputHandler->CancelIMEComposition();
      return NS_OK;
    case NOTIFY_IME_OF_FOCUS:
      if (mInputContext.IsPasswordEditor()) {
        TextInputHandler::EnableSecureEventInput();
      } else {
        TextInputHandler::EnsureSecureEventInputDisabled();
      }

      NS_ENSURE_TRUE(mTextInputHandler, NS_ERROR_NOT_AVAILABLE);
      mTextInputHandler->OnFocusChangeInGoanna(true);
      return NS_OK;
    case NOTIFY_IME_OF_BLUR:
      // When we're going to be deactive, we must disable the secure event input
      // mode, see the Carbon Event Manager Reference.
      TextInputHandler::EnsureSecureEventInputDisabled();

      NS_ENSURE_TRUE(mTextInputHandler, NS_ERROR_NOT_AVAILABLE);
      mTextInputHandler->OnFocusChangeInGoanna(false);
      return NS_OK;
    case NOTIFY_IME_OF_SELECTION_CHANGE:
      NS_ENSURE_TRUE(mTextInputHandler, NS_ERROR_NOT_AVAILABLE);
      mTextInputHandler->OnSelectionChange();
    default:
      return NS_ERROR_NOT_IMPLEMENTED;
  }
}

NS_IMETHODIMP
nsChildView::StartPluginIME(const mozilla::WidgetKeyboardEvent& aKeyboardEvent,
                            int32_t aPanelX, int32_t aPanelY,
                            nsString& aCommitted)
{
  NS_ENSURE_TRUE(mView, NS_ERROR_NOT_AVAILABLE);

  ComplexTextInputPanel* ctiPanel =
    ComplexTextInputPanel::GetSharedComplexTextInputPanel();

  ctiPanel->PlacePanel(aPanelX, aPanelY);
  // We deliberately don't use TextInputHandler::GetCurrentKeyEvent() to
  // obtain the NSEvent* we pass to InterpretKeyEvent().  This works fine in
  // non-e10s mode.  But in e10s mode TextInputHandler::HandleKeyDownEvent()
  // has already returned, so the relevant KeyEventState* (and its NSEvent*)
  // is already out of scope.  Furthermore we don't *need* to use it.
  // StartPluginIME() is only ever called to start a new IME session when none
  // currently exists.  So nested IME should never reach here, and so it should
  // be fine to use the last key-down event received by -[ChildView keyDown:]
  // (as we currently do).
  ctiPanel->InterpretKeyEvent([mView lastKeyDownEvent], aCommitted);

  return NS_OK;
}

NS_IMETHODIMP
nsChildView::SetPluginFocused(bool& aFocused)
{
  if (aFocused == mPluginFocused) {
    return NS_OK;
  }
  if (!aFocused) {
    ComplexTextInputPanel* ctiPanel =
      ComplexTextInputPanel::GetSharedComplexTextInputPanel();
    if (ctiPanel) {
      ctiPanel->CancelComposition();
    }
  }
  mPluginFocused = aFocused;
  return NS_OK;
}

NS_IMETHODIMP_(void)
nsChildView::SetInputContext(const InputContext& aContext,
                             const InputContextAction& aAction)
{
  NS_ENSURE_TRUE_VOID(mTextInputHandler);

  if (mTextInputHandler->IsOrWouldBeFocused()) {
    if (aContext.IsPasswordEditor()) {
      TextInputHandler::EnableSecureEventInput();
    } else {
      TextInputHandler::EnsureSecureEventInputDisabled();
    }
  }

  mInputContext = aContext;
  switch (aContext.mIMEState.mEnabled) {
    case IMEState::ENABLED:
    case IMEState::PLUGIN:
      mTextInputHandler->SetASCIICapableOnly(false);
      mTextInputHandler->EnableIME(true);
      if (mInputContext.mIMEState.mOpen != IMEState::DONT_CHANGE_OPEN_STATE) {
        mTextInputHandler->SetIMEOpenState(
          mInputContext.mIMEState.mOpen == IMEState::OPEN);
      }
      break;
    case IMEState::DISABLED:
      mTextInputHandler->SetASCIICapableOnly(false);
      mTextInputHandler->EnableIME(false);
      break;
    case IMEState::PASSWORD:
      mTextInputHandler->SetASCIICapableOnly(true);
      mTextInputHandler->EnableIME(false);
      break;
    default:
      NS_ERROR("not implemented!");
  }
}

NS_IMETHODIMP_(InputContext)
nsChildView::GetInputContext()
{
  switch (mInputContext.mIMEState.mEnabled) {
    case IMEState::ENABLED:
    case IMEState::PLUGIN:
      if (mTextInputHandler) {
        mInputContext.mIMEState.mOpen =
          mTextInputHandler->IsIMEOpened() ? IMEState::OPEN : IMEState::CLOSED;
        break;
      }
      // If mTextInputHandler is null, set CLOSED instead...
    default:
      mInputContext.mIMEState.mOpen = IMEState::CLOSED;
      break;
  }
  mInputContext.mNativeIMEContext = [mView inputContext];
  // If input context isn't available on this widget, we should set |this|
  // instead of nullptr since nullptr means that the platform has only one
  // context per process.
  if (!mInputContext.mNativeIMEContext) {
    mInputContext.mNativeIMEContext = this;
  }
  return mInputContext;
}

NS_IMETHODIMP
nsChildView::AttachNativeKeyEvent(mozilla::WidgetKeyboardEvent& aEvent)
{
  NS_ENSURE_TRUE(mTextInputHandler, NS_ERROR_NOT_AVAILABLE);
  return mTextInputHandler->AttachNativeKeyEvent(aEvent);
}

bool
nsChildView::ExecuteNativeKeyBindingRemapped(NativeKeyBindingsType aType,
                                             const WidgetKeyboardEvent& aEvent,
                                             DoCommandCallback aCallback,
                                             void* aCallbackData,
                                             uint32_t aGoannaKeyCode,
                                             uint32_t aCocoaKeyCode)
{
  NSEvent *originalEvent = reinterpret_cast<NSEvent*>(aEvent.mNativeKeyEvent);

  WidgetKeyboardEvent modifiedEvent(aEvent);
  modifiedEvent.keyCode = aGoannaKeyCode;

  unichar ch = nsCocoaUtils::ConvertGoannaKeyCodeToMacCharCode(aGoannaKeyCode);
  NSString *chars =
    [[[NSString alloc] initWithCharacters:&ch length:1] autorelease];

  modifiedEvent.mNativeKeyEvent =
    [NSEvent keyEventWithType:[originalEvent type]
                     location:[originalEvent locationInWindow]
                modifierFlags:[originalEvent modifierFlags]
                    timestamp:[originalEvent timestamp]
                 windowNumber:[originalEvent windowNumber]
                      context:[originalEvent context]
                   characters:chars
  charactersIgnoringModifiers:chars
                    isARepeat:[originalEvent isARepeat]
                      keyCode:aCocoaKeyCode];

  NativeKeyBindings* keyBindings = NativeKeyBindings::GetInstance(aType);
  return keyBindings->Execute(modifiedEvent, aCallback, aCallbackData);
}

NS_IMETHODIMP_(bool)
nsChildView::ExecuteNativeKeyBinding(NativeKeyBindingsType aType,
                                     const WidgetKeyboardEvent& aEvent,
                                     DoCommandCallback aCallback,
                                     void* aCallbackData)
{
  // If the key is a cursor-movement arrow, and the current selection has
  // vertical writing-mode, we'll remap so that the movement command
  // generated (in terms of characters/lines) will be appropriate for
  // the physical direction of the arrow.
  if (aEvent.keyCode >= nsIDOMKeyEvent::DOM_VK_LEFT &&
      aEvent.keyCode <= nsIDOMKeyEvent::DOM_VK_DOWN) {
    WidgetQueryContentEvent query(true, NS_QUERY_SELECTED_TEXT, this);
    DispatchWindowEvent(query);

    if (query.mSucceeded && query.mReply.mWritingMode.IsVertical()) {
      uint32_t goannaKey = 0;
      uint32_t cocoaKey = 0;

      switch (aEvent.keyCode) {
      case nsIDOMKeyEvent::DOM_VK_LEFT:
        if (query.mReply.mWritingMode.IsVerticalLR()) {
          goannaKey = nsIDOMKeyEvent::DOM_VK_UP;
          cocoaKey = kVK_UpArrow;
        } else {
          goannaKey = nsIDOMKeyEvent::DOM_VK_DOWN;
          cocoaKey = kVK_DownArrow;
        }
        break;

      case nsIDOMKeyEvent::DOM_VK_RIGHT:
        if (query.mReply.mWritingMode.IsVerticalLR()) {
          goannaKey = nsIDOMKeyEvent::DOM_VK_DOWN;
          cocoaKey = kVK_DownArrow;
        } else {
          goannaKey = nsIDOMKeyEvent::DOM_VK_UP;
          cocoaKey = kVK_UpArrow;
        }
        break;

      case nsIDOMKeyEvent::DOM_VK_UP:
        goannaKey = nsIDOMKeyEvent::DOM_VK_LEFT;
        cocoaKey = kVK_LeftArrow;
        break;

      case nsIDOMKeyEvent::DOM_VK_DOWN:
        goannaKey = nsIDOMKeyEvent::DOM_VK_RIGHT;
        cocoaKey = kVK_RightArrow;
        break;
      }

      return ExecuteNativeKeyBindingRemapped(aType, aEvent, aCallback,
                                             aCallbackData,
                                             goannaKey, cocoaKey);
    }
  }

  NativeKeyBindings* keyBindings = NativeKeyBindings::GetInstance(aType);
  return keyBindings->Execute(aEvent, aCallback, aCallbackData);
}

nsIMEUpdatePreference
nsChildView::GetIMEUpdatePreference()
{
  return nsIMEUpdatePreference(nsIMEUpdatePreference::NOTIFY_SELECTION_CHANGE);
}

NS_IMETHODIMP nsChildView::GetToggledKeyState(uint32_t aKeyCode,
                                              bool* aLEDState)
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_NSRESULT;

  NS_ENSURE_ARG_POINTER(aLEDState);
  uint32_t key;
  switch (aKeyCode) {
    case NS_VK_CAPS_LOCK:
      key = alphaLock;
      break;
    case NS_VK_NUM_LOCK:
      key = kEventKeyModifierNumLockMask;
      break;
    // Mac doesn't support SCROLL_LOCK state.
    default:
      return NS_ERROR_NOT_IMPLEMENTED;
  }
  uint32_t modifierFlags = ::GetCurrentKeyModifiers();
  *aLEDState = (modifierFlags & key) != 0;
  return NS_OK;

  NS_OBJC_END_TRY_ABORT_BLOCK_NSRESULT;
}

NSView<mozView>* nsChildView::GetEditorView()
{
  NSView<mozView>* editorView = mView;
  // We need to get editor's view. E.g., when the focus is in the bookmark
  // dialog, the view is <panel> element of the dialog.  At this time, the key
  // events are processed the parent window's view that has native focus.
  WidgetQueryContentEvent textContent(true, NS_QUERY_TEXT_CONTENT, this);
  textContent.InitForQueryTextContent(0, 0);
  DispatchWindowEvent(textContent);
  if (textContent.mSucceeded && textContent.mReply.mFocusedWidget) {
    NSView<mozView>* view = static_cast<NSView<mozView>*>(
      textContent.mReply.mFocusedWidget->GetNativeData(NS_NATIVE_WIDGET));
    if (view)
      editorView = view;
  }
  return editorView;
}

#pragma mark -

void
nsChildView::CreateCompositor()
{
  nsBaseWidget::CreateCompositor();
  if (mCompositorChild) {
    [(ChildView *)mView setUsingOMTCompositor:true];
  }
}

void
nsChildView::ConfigureAPZCTreeManager()
{
  nsBaseWidget::ConfigureAPZCTreeManager();

  if (gNumberOfWidgetsNeedingEventThread == 0) {
    [EventThreadRunner start];
  }
  gNumberOfWidgetsNeedingEventThread++;
}

nsIntRect
nsChildView::RectContainingTitlebarControls()
{
  // Start with a thin strip at the top of the window for the highlight line.
  NSRect rect = NSMakeRect(0, 0, [mView bounds].size.width,
                           [(ChildView*)mView cornerRadius]);

  // Add the rects of the titlebar controls.
  for (id view in [(BaseWindow*)[mView window] titlebarControls]) {
    rect = NSUnionRect(rect, [mView convertRect:[view bounds] fromView:view]);
  }
  return CocoaPointsToDevPixels(rect);
}

void
nsChildView::PrepareWindowEffects()
{
  MutexAutoLock lock(mEffectsLock);
  mShowsResizeIndicator = ShowsResizeIndicator(&mResizeIndicatorRect);
  mHasRoundedBottomCorners = [(ChildView*)mView hasRoundedBottomCorners];
  CGFloat cornerRadius = [(ChildView*)mView cornerRadius];
  mDevPixelCornerRadius = cornerRadius * BackingScaleFactor();
  mIsCoveringTitlebar = [(ChildView*)mView isCoveringTitlebar];
  mIsFullscreen = ([[mView window] styleMask] & NSFullScreenWindowMask) != 0;
  if (mIsCoveringTitlebar) {
    mTitlebarRect = RectContainingTitlebarControls();
    UpdateTitlebarCGContext();
  }
}

void
nsChildView::CleanupWindowEffects()
{
  mResizerImage = nullptr;
  mCornerMaskImage = nullptr;
  mTitlebarImage = nullptr;
}

bool
nsChildView::PreRender(LayerManagerComposite* aManager)
{
  nsAutoPtr<GLManager> manager(GLManager::CreateGLManager(aManager));
  if (!manager) {
    return true;
  }

  // The lock makes sure that we don't attempt to tear down the view while
  // compositing. That would make us unable to call postRender on it when the
  // composition is done, thus keeping the GL context locked forever.
  mViewTearDownLock.Lock();

  NSOpenGLContext *glContext = GLContextCGL::Cast(manager->gl())->GetNSOpenGLContext();

  if (![(ChildView*)mView preRender:glContext]) {
    mViewTearDownLock.Unlock();
    return false;
  }
  return true;
}

void
nsChildView::PostRender(LayerManagerComposite* aManager)
{
  nsAutoPtr<GLManager> manager(GLManager::CreateGLManager(aManager));
  if (!manager) {
    return;
  }
  NSOpenGLContext *glContext = GLContextCGL::Cast(manager->gl())->GetNSOpenGLContext();
  [(ChildView*)mView postRender:glContext];
  mViewTearDownLock.Unlock();
}

void
nsChildView::DrawWindowOverlay(LayerManagerComposite* aManager, nsIntRect aRect)
{
  nsAutoPtr<GLManager> manager(GLManager::CreateGLManager(aManager));
  if (manager) {
    DrawWindowOverlay(manager, aRect);
  }
}

void
nsChildView::DrawWindowOverlay(GLManager* aManager, nsIntRect aRect)
{
  GLContext* gl = aManager->gl();
  ScopedGLState scopedScissorTestState(gl, LOCAL_GL_SCISSOR_TEST, false);

  MaybeDrawTitlebar(aManager, aRect);
  MaybeDrawResizeIndicator(aManager, aRect);
  MaybeDrawRoundedCorners(aManager, aRect);
}

static void
ClearRegion(gfx::DrawTarget *aDT, nsIntRegion aRegion)
{
  gfxUtils::ClipToRegion(aDT, aRegion);
  aDT->ClearRect(gfx::Rect(0, 0, aDT->GetSize().width, aDT->GetSize().height));
  aDT->PopClip();
}

static void
DrawResizer(CGContextRef aCtx)
{
  CGContextSetShouldAntialias(aCtx, false);
  CGPoint points[6];
  points[0] = CGPointMake(13.0f, 4.0f);
  points[1] = CGPointMake(3.0f, 14.0f);
  points[2] = CGPointMake(13.0f, 8.0f);
  points[3] = CGPointMake(7.0f, 14.0f);
  points[4] = CGPointMake(13.0f, 12.0f);
  points[5] = CGPointMake(11.0f, 14.0f);
  CGContextSetRGBStrokeColor(aCtx, 0.00f, 0.00f, 0.00f, 0.15f);
  CGContextStrokeLineSegments(aCtx, points, 6);

  points[0] = CGPointMake(13.0f, 5.0f);
  points[1] = CGPointMake(4.0f, 14.0f);
  points[2] = CGPointMake(13.0f, 9.0f);
  points[3] = CGPointMake(8.0f, 14.0f);
  points[4] = CGPointMake(13.0f, 13.0f);
  points[5] = CGPointMake(12.0f, 14.0f);
  CGContextSetRGBStrokeColor(aCtx, 0.13f, 0.13f, 0.13f, 0.54f);
  CGContextStrokeLineSegments(aCtx, points, 6);

  points[0] = CGPointMake(13.0f, 6.0f);
  points[1] = CGPointMake(5.0f, 14.0f);
  points[2] = CGPointMake(13.0f, 10.0f);
  points[3] = CGPointMake(9.0f, 14.0f);
  points[5] = CGPointMake(13.0f, 13.9f);
  points[4] = CGPointMake(13.0f, 14.0f);
  CGContextSetRGBStrokeColor(aCtx, 0.84f, 0.84f, 0.84f, 0.55f);
  CGContextStrokeLineSegments(aCtx, points, 6);
}

void
nsChildView::MaybeDrawResizeIndicator(GLManager* aManager, const nsIntRect& aRect)
{
  MutexAutoLock lock(mEffectsLock);
  if (!mShowsResizeIndicator) {
    return;
  }

  if (!mResizerImage) {
    mResizerImage = new RectTextureImage(aManager->gl());
  }

  nsIntSize size = mResizeIndicatorRect.Size();
  mResizerImage->UpdateIfNeeded(size, nsIntRegion(), ^(gfx::DrawTarget* drawTarget, const nsIntRegion& updateRegion) {
    ClearRegion(drawTarget, updateRegion);
    gfx::BorrowedCGContext borrow(drawTarget);
    DrawResizer(borrow.cg);
    borrow.Finish();
  });

  mResizerImage->Draw(aManager, mResizeIndicatorRect.TopLeft());
}

// Draw the highlight line at the top of the titlebar.
// This function draws into the current NSGraphicsContext and assumes flippedness.
static void
DrawTitlebarHighlight(NSSize aWindowSize, CGFloat aRadius, CGFloat aDevicePixelWidth)
{
  [NSGraphicsContext saveGraphicsState];

  // Set up the clip path. We start with the outer rectangle and cut out a
  // slightly smaller inner rectangle with rounded corners.
  // The outer corners of the resulting path will be square, but they will be
  // masked away in a later step.
  NSBezierPath* path = [NSBezierPath bezierPath];
  [path setWindingRule:NSEvenOddWindingRule];
  NSRect pathRect = NSMakeRect(0, 0, aWindowSize.width, aRadius + 2);
  [path appendBezierPathWithRect:pathRect];
  pathRect = NSInsetRect(pathRect, aDevicePixelWidth, aDevicePixelWidth);
  CGFloat innerRadius = aRadius - aDevicePixelWidth;
  [path appendBezierPathWithRoundedRect:pathRect xRadius:innerRadius yRadius:innerRadius];
  [path addClip];

  // Now we fill the path with a subtle highlight gradient.
  // We don't use NSGradient because it's 5x to 15x slower than the manual fill,
  // as indicated by the performance test in bug 880620.
  for (CGFloat y = 0; y < aRadius; y += aDevicePixelWidth) {
    CGFloat t = y / aRadius;
    [[NSColor colorWithDeviceWhite:1.0 alpha:0.4 * (1.0 - t)] set];
    NSRectFillUsingOperation(NSMakeRect(0, y, aWindowSize.width, aDevicePixelWidth), NSCompositeSourceOver);
  }

  [NSGraphicsContext restoreGraphicsState];
}

static CGContextRef
CreateCGContext(const nsIntSize& aSize)
{
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  CGContextRef ctx =
    CGBitmapContextCreate(NULL,
                          aSize.width,
                          aSize.height,
                          8 /* bitsPerComponent */,
                          aSize.width * 4,
                          cs,
                          kCGBitmapByteOrder32Host | kCGImageAlphaPremultipliedFirst);
  CGColorSpaceRelease(cs);

  CGContextTranslateCTM(ctx, 0, aSize.height);
  CGContextScaleCTM(ctx, 1, -1);
  CGContextSetInterpolationQuality(ctx, kCGInterpolationLow);

  return ctx;
}

// When this method is entered, mEffectsLock is already being held.
void
nsChildView::UpdateTitlebarCGContext()
{
  if (mTitlebarRect.IsEmpty()) {
    ReleaseTitlebarCGContext();
    return;
  }

  NSRect titlebarRect = DevPixelsToCocoaPoints(mTitlebarRect);
  NSRect dirtyRect = [mView convertRect:[(BaseWindow*)[mView window] getAndResetNativeDirtyRect] fromView:nil];
  NSRect dirtyTitlebarRect = NSIntersectionRect(titlebarRect, dirtyRect);

  nsIntSize texSize = RectTextureImage::TextureSizeForSize(mTitlebarRect.Size());
  if (!mTitlebarCGContext ||
      CGBitmapContextGetWidth(mTitlebarCGContext) != size_t(texSize.width) ||
      CGBitmapContextGetHeight(mTitlebarCGContext) != size_t(texSize.height)) {
    dirtyTitlebarRect = titlebarRect;

    ReleaseTitlebarCGContext();

    mTitlebarCGContext = CreateCGContext(texSize);
  }

  if (NSIsEmptyRect(dirtyTitlebarRect)) {
    return;
  }

  CGContextRef ctx = mTitlebarCGContext;

  CGContextSaveGState(ctx);

  double scale = BackingScaleFactor();
  CGContextScaleCTM(ctx, scale, scale);

  CGContextClipToRect(ctx, NSRectToCGRect(dirtyTitlebarRect));
  CGContextClearRect(ctx, NSRectToCGRect(dirtyTitlebarRect));

  NSGraphicsContext* oldContext = [NSGraphicsContext currentContext];

  CGContextSaveGState(ctx);

  BaseWindow* window = (BaseWindow*)[mView window];
  NSView* frameView = [[window contentView] superview];
  if (![frameView isFlipped]) {
    CGContextTranslateCTM(ctx, 0, [frameView bounds].size.height);
    CGContextScaleCTM(ctx, 1, -1);
  }
  NSGraphicsContext* context = [NSGraphicsContext graphicsContextWithGraphicsPort:ctx flipped:[frameView isFlipped]];
  [NSGraphicsContext setCurrentContext:context];

  // Draw the title string.
  if ([window wantsTitleDrawn] && [frameView respondsToSelector:@selector(_drawTitleBar:)]) {
    [frameView _drawTitleBar:[frameView bounds]];
  }

  // Draw the titlebar controls into the titlebar image.
  for (id view in [window titlebarControls]) {
    NSRect viewFrame = [view frame];
    NSRect viewRect = [mView convertRect:viewFrame fromView:frameView];
    if (!NSIntersectsRect(dirtyTitlebarRect, viewRect)) {
      continue;
    }
    // All of the titlebar controls we're interested in are subclasses of
    // NSButton.
    if (![view isKindOfClass:[NSButton class]]) {
      continue;
    }
    NSButton *button = (NSButton *) view;
    id cellObject = [button cell];
    if (![cellObject isKindOfClass:[NSCell class]]) {
      continue;
    }
    NSCell *cell = (NSCell *) cellObject;

    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, viewFrame.origin.x, viewFrame.origin.y);

    if ([context isFlipped] != [view isFlipped]) {
      CGContextTranslateCTM(ctx, 0, viewFrame.size.height);
      CGContextScaleCTM(ctx, 1, -1);
    }

    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithGraphicsPort:ctx flipped:[view isFlipped]]];

    if ([window useBrightTitlebarForeground] && !nsCocoaFeatures::OnYosemiteOrLater() &&
        view == [window standardWindowButton:NSWindowFullScreenButton]) {
      // Make the fullscreen button visible on dark titlebar backgrounds by
      // drawing it into a new transparency layer and turning it white.
      CGRect r = NSRectToCGRect([view bounds]);
      CGContextBeginTransparencyLayerWithRect(ctx, r, nullptr);

      // Draw twice for double opacity.
      [cell drawWithFrame:[button bounds] inView:button];
      [cell drawWithFrame:[button bounds] inView:button];

      // Make it white.
      CGContextSetBlendMode(ctx, kCGBlendModeSourceIn);
      CGContextSetRGBFillColor(ctx, 1, 1, 1, 1);
      CGContextFillRect(ctx, r);
      CGContextSetBlendMode(ctx, kCGBlendModeNormal);

      CGContextEndTransparencyLayer(ctx);
    } else {
      [cell drawWithFrame:[button bounds] inView:button];
    }

    [NSGraphicsContext setCurrentContext:context];
    CGContextRestoreGState(ctx);
  }

  CGContextRestoreGState(ctx);

  DrawTitlebarHighlight([frameView bounds].size, [(ChildView*)mView cornerRadius],
                        DevPixelsToCocoaPoints(1));

  [NSGraphicsContext setCurrentContext:oldContext];

  CGContextRestoreGState(ctx);

  mUpdatedTitlebarRegion.OrWith(CocoaPointsToDevPixels(dirtyTitlebarRect));
}

// This method draws an overlay in the top of the window which contains the
// titlebar controls (e.g. close, min, zoom, fullscreen) and the titlebar
// highlight effect.
// This is necessary because the real titlebar controls are covered by our
// OpenGL context. Note that in terms of the NSView hierarchy, our ChildView
// is actually below the titlebar controls - that's why hovering and clicking
// them works as expected - but their visual representation is only drawn into
// the normal window buffer, and the window buffer surface lies below the
// GLContext surface. In order to make the titlebar controls visible, we have
// to redraw them inside the OpenGL context surface.
void
nsChildView::MaybeDrawTitlebar(GLManager* aManager, const nsIntRect& aRect)
{
  MutexAutoLock lock(mEffectsLock);
  if (!mIsCoveringTitlebar || mIsFullscreen) {
    return;
  }

  nsIntRegion updatedTitlebarRegion;
  updatedTitlebarRegion.And(mUpdatedTitlebarRegion, mTitlebarRect);
  mUpdatedTitlebarRegion.SetEmpty();

  if (!mTitlebarImage) {
    mTitlebarImage = new RectTextureImage(aManager->gl());
  }

  mTitlebarImage->UpdateFromCGContext(mTitlebarRect.Size(),
                                      updatedTitlebarRegion,
                                      mTitlebarCGContext);

  mTitlebarImage->Draw(aManager, mTitlebarRect.TopLeft());
}

static void
DrawTopLeftCornerMask(CGContextRef aCtx, int aRadius)
{
  CGContextSetRGBFillColor(aCtx, 1.0, 1.0, 1.0, 1.0);
  CGContextFillEllipseInRect(aCtx, CGRectMake(0, 0, aRadius * 2, aRadius * 2));
}

void
nsChildView::MaybeDrawRoundedCorners(GLManager* aManager, const nsIntRect& aRect)
{
  MutexAutoLock lock(mEffectsLock);

  if (!mCornerMaskImage) {
    mCornerMaskImage = new RectTextureImage(aManager->gl());
  }

  nsIntSize size(mDevPixelCornerRadius, mDevPixelCornerRadius);
  mCornerMaskImage->UpdateIfNeeded(size, nsIntRegion(), ^(gfx::DrawTarget* drawTarget, const nsIntRegion& updateRegion) {
    ClearRegion(drawTarget, updateRegion);
    RefPtr<gfx::PathBuilder> builder = drawTarget->CreatePathBuilder();
    builder->Arc(gfx::Point(mDevPixelCornerRadius, mDevPixelCornerRadius), mDevPixelCornerRadius, 0, 2.0f * M_PI);
    RefPtr<gfx::Path> path = builder->Finish();
    drawTarget->Fill(path,
                     gfx::ColorPattern(gfx::Color(1.0, 1.0, 1.0, 1.0)),
                     gfx::DrawOptions(1.0f, gfx::CompositionOp::OP_SOURCE));
  });

  // Use operator destination in: multiply all 4 channels with source alpha.
  aManager->gl()->fBlendFuncSeparate(LOCAL_GL_ZERO, LOCAL_GL_SRC_ALPHA,
                                     LOCAL_GL_ZERO, LOCAL_GL_SRC_ALPHA);

  Matrix4x4 flipX = Matrix4x4::Scaling(-1, 1, 1);
  Matrix4x4 flipY = Matrix4x4::Scaling(1, -1, 1);

  if (mIsCoveringTitlebar && !mIsFullscreen) {
    // Mask the top corners.
    mCornerMaskImage->Draw(aManager, aRect.TopLeft());
    mCornerMaskImage->Draw(aManager, aRect.TopRight(), flipX);
  }

  if (mHasRoundedBottomCorners && !mIsFullscreen) {
    // Mask the bottom corners.
    mCornerMaskImage->Draw(aManager, aRect.BottomLeft(), flipY);
    mCornerMaskImage->Draw(aManager, aRect.BottomRight(), flipY * flipX);
  }

  // Reset blend mode.
  aManager->gl()->fBlendFuncSeparate(LOCAL_GL_ONE, LOCAL_GL_ONE_MINUS_SRC_ALPHA,
                                     LOCAL_GL_ONE, LOCAL_GL_ONE);
}

static int32_t
FindTitlebarBottom(const nsTArray<nsIWidget::ThemeGeometry>& aThemeGeometries,
                   int32_t aWindowWidth)
{
  int32_t titlebarBottom = 0;
  for (uint32_t i = 0; i < aThemeGeometries.Length(); ++i) {
    const nsIWidget::ThemeGeometry& g = aThemeGeometries[i];
    if ((g.mType == nsNativeThemeCocoa::eThemeGeometryTypeTitlebar) &&
        g.mRect.X() <= 0 &&
        g.mRect.XMost() >= aWindowWidth &&
        g.mRect.Y() <= 0) {
      titlebarBottom = std::max(titlebarBottom, g.mRect.YMost());
    }
  }
  return titlebarBottom;
}

static int32_t
FindUnifiedToolbarBottom(const nsTArray<nsIWidget::ThemeGeometry>& aThemeGeometries,
                         int32_t aWindowWidth, int32_t aTitlebarBottom)
{
  int32_t unifiedToolbarBottom = aTitlebarBottom;
  for (uint32_t i = 0; i < aThemeGeometries.Length(); ++i) {
    const nsIWidget::ThemeGeometry& g = aThemeGeometries[i];
    if ((g.mType == nsNativeThemeCocoa::eThemeGeometryTypeToolbar) &&
        g.mRect.X() <= 0 &&
        g.mRect.XMost() >= aWindowWidth &&
        g.mRect.Y() <= aTitlebarBottom) {
      unifiedToolbarBottom = std::max(unifiedToolbarBottom, g.mRect.YMost());
    }
  }
  return unifiedToolbarBottom;
}

static nsIntRect
FindFirstRectOfType(const nsTArray<nsIWidget::ThemeGeometry>& aThemeGeometries,
                    nsITheme::ThemeGeometryType aThemeGeometryType)
{
  for (uint32_t i = 0; i < aThemeGeometries.Length(); ++i) {
    const nsIWidget::ThemeGeometry& g = aThemeGeometries[i];
    if (g.mType == aThemeGeometryType) {
      return g.mRect;
    }
  }
  return nsIntRect();
}

void
nsChildView::UpdateThemeGeometries(const nsTArray<ThemeGeometry>& aThemeGeometries)
{
  if (![mView window])
    return;

  UpdateVibrancy(aThemeGeometries);

  if (![[mView window] isKindOfClass:[ToolbarWindow class]])
    return;

  // Update unified toolbar height.
  int32_t windowWidth = mBounds.width;
  int32_t titlebarBottom = FindTitlebarBottom(aThemeGeometries, windowWidth);
  int32_t unifiedToolbarBottom =
    FindUnifiedToolbarBottom(aThemeGeometries, windowWidth, titlebarBottom);

  ToolbarWindow* win = (ToolbarWindow*)[mView window];
  bool drawsContentsIntoWindowFrame = [win drawsContentsIntoWindowFrame];
  int32_t titlebarHeight = CocoaPointsToDevPixels([win titlebarHeight]);
  int32_t contentOffset = drawsContentsIntoWindowFrame ? titlebarHeight : 0;
  int32_t devUnifiedHeight = titlebarHeight + unifiedToolbarBottom - contentOffset;
  [win setUnifiedToolbarHeight:DevPixelsToCocoaPoints(devUnifiedHeight)];

  // Update titlebar control offsets.
  nsIntRect windowButtonRect = FindFirstRectOfType(aThemeGeometries, nsNativeThemeCocoa::eThemeGeometryTypeWindowButtons);
  [win placeWindowButtons:[mView convertRect:DevPixelsToCocoaPoints(windowButtonRect) toView:nil]];
  nsIntRect fullScreenButtonRect = FindFirstRectOfType(aThemeGeometries, nsNativeThemeCocoa::eThemeGeometryTypeFullscreenButton);
  [win placeFullScreenButton:[mView convertRect:DevPixelsToCocoaPoints(fullScreenButtonRect) toView:nil]];
}

static nsIntRegion
GatherThemeGeometryRegion(const nsTArray<nsIWidget::ThemeGeometry>& aThemeGeometries,
                          nsITheme::ThemeGeometryType aThemeGeometryType)
{
  nsIntRegion region;
  for (size_t i = 0; i < aThemeGeometries.Length(); ++i) {
    const nsIWidget::ThemeGeometry& g = aThemeGeometries[i];
    if (g.mType == aThemeGeometryType) {
      region.OrWith(g.mRect);
    }
  }
  return region;
}

template<typename Region>
static void MakeRegionsNonOverlappingImpl(Region& aOutUnion) { }

template<typename Region, typename ... Regions>
static void MakeRegionsNonOverlappingImpl(Region& aOutUnion, Region& aFirst, Regions& ... aRest)
{
  MakeRegionsNonOverlappingImpl(aOutUnion, aRest...);
  aFirst.SubOut(aOutUnion);
  aOutUnion.OrWith(aFirst);
}

// Subtracts parts from regions in such a way that they don't have any overlap.
// Each region in the argument list will have the union of all the regions
// *following* it subtracted from itself. In other words, the arguments are
// sorted low priority to high priority.
template<typename Region, typename ... Regions>
static void MakeRegionsNonOverlapping(Region& aFirst, Regions& ... aRest)
{
  Region unionOfAll;
  MakeRegionsNonOverlappingImpl(unionOfAll, aFirst, aRest...);
}

void
nsChildView::UpdateVibrancy(const nsTArray<ThemeGeometry>& aThemeGeometries)
{
  if (!VibrancyManager::SystemSupportsVibrancy()) {
    return;
  }

  nsIntRegion vibrantLightRegion =
    GatherThemeGeometryRegion(aThemeGeometries, nsNativeThemeCocoa::eThemeGeometryTypeVibrancyLight);
  nsIntRegion vibrantDarkRegion =
    GatherThemeGeometryRegion(aThemeGeometries, nsNativeThemeCocoa::eThemeGeometryTypeVibrancyDark);
  nsIntRegion menuRegion =
    GatherThemeGeometryRegion(aThemeGeometries, nsNativeThemeCocoa::eThemeGeometryTypeMenu);
  nsIntRegion tooltipRegion =
    GatherThemeGeometryRegion(aThemeGeometries, nsNativeThemeCocoa::eThemeGeometryTypeTooltip);
  nsIntRegion highlightedMenuItemRegion =
    GatherThemeGeometryRegion(aThemeGeometries, nsNativeThemeCocoa::eThemeGeometryTypeHighlightedMenuItem);

  MakeRegionsNonOverlapping(vibrantLightRegion, vibrantDarkRegion, menuRegion,
                            tooltipRegion, highlightedMenuItemRegion);

  auto& vm = EnsureVibrancyManager();
  vm.UpdateVibrantRegion(VibrancyType::LIGHT, vibrantLightRegion);
  vm.UpdateVibrantRegion(VibrancyType::TOOLTIP, tooltipRegion);
  vm.UpdateVibrantRegion(VibrancyType::MENU, menuRegion);
  vm.UpdateVibrantRegion(VibrancyType::HIGHLIGHTED_MENUITEM, highlightedMenuItemRegion);
  vm.UpdateVibrantRegion(VibrancyType::DARK, vibrantDarkRegion);
}

void
nsChildView::ClearVibrantAreas()
{
  if (VibrancyManager::SystemSupportsVibrancy()) {
    EnsureVibrancyManager().ClearVibrantAreas();
  }
}

static VibrancyType
ThemeGeometryTypeToVibrancyType(nsITheme::ThemeGeometryType aThemeGeometryType)
{
  switch (aThemeGeometryType) {
    case nsNativeThemeCocoa::eThemeGeometryTypeVibrancyLight:
      return VibrancyType::LIGHT;
    case nsNativeThemeCocoa::eThemeGeometryTypeVibrancyDark:
      return VibrancyType::DARK;
    case nsNativeThemeCocoa::eThemeGeometryTypeTooltip:
      return VibrancyType::TOOLTIP;
    case nsNativeThemeCocoa::eThemeGeometryTypeMenu:
      return VibrancyType::MENU;
    case nsNativeThemeCocoa::eThemeGeometryTypeHighlightedMenuItem:
      return VibrancyType::HIGHLIGHTED_MENUITEM;
    default:
      MOZ_CRASH();
  }
}

NSColor*
nsChildView::VibrancyFillColorForThemeGeometryType(nsITheme::ThemeGeometryType aThemeGeometryType)
{
  if (VibrancyManager::SystemSupportsVibrancy()) {
    return EnsureVibrancyManager().VibrancyFillColorForType(
      ThemeGeometryTypeToVibrancyType(aThemeGeometryType));
  }
  return [NSColor whiteColor];
}

NSColor*
nsChildView::VibrancyFontSmoothingBackgroundColorForThemeGeometryType(nsITheme::ThemeGeometryType aThemeGeometryType)
{
  if (VibrancyManager::SystemSupportsVibrancy()) {
    return EnsureVibrancyManager().VibrancyFontSmoothingBackgroundColorForType(
      ThemeGeometryTypeToVibrancyType(aThemeGeometryType));
  }
  return [NSColor clearColor];
}

mozilla::VibrancyManager&
nsChildView::EnsureVibrancyManager()
{
  MOZ_ASSERT(mView, "Only call this once we have a view!");
  if (!mVibrancyManager) {
    mVibrancyManager = MakeUnique<VibrancyManager>(*this, mView);
  }
  return *mVibrancyManager;
}

TemporaryRef<gfx::DrawTarget>
nsChildView::StartRemoteDrawing()
{
  if (!mGLPresenter) {
    mGLPresenter = GLPresenter::CreateForWindow(this);

    if (!mGLPresenter) {
      return nullptr;
    }
  }

  nsIntRegion dirtyRegion = mBounds;
  nsIntSize renderSize = mBounds.Size();

  if (!mBasicCompositorImage) {
    mBasicCompositorImage = new RectTextureImage(mGLPresenter->gl());
  }

  RefPtr<gfx::DrawTarget> drawTarget =
    mBasicCompositorImage->BeginUpdate(renderSize, dirtyRegion);

  if (!drawTarget) {
    // Composite unchanged textures.
    DoRemoteComposition(mBounds);
    return nullptr;
  }

  return drawTarget;
}

void
nsChildView::EndRemoteDrawing()
{
  mBasicCompositorImage->EndUpdate(true);
  DoRemoteComposition(mBounds);
}

void
nsChildView::CleanupRemoteDrawing()
{
  mBasicCompositorImage = nullptr;
  mCornerMaskImage = nullptr;
  mResizerImage = nullptr;
  mTitlebarImage = nullptr;
  mGLPresenter = nullptr;
}

void
nsChildView::DoRemoteComposition(const nsIntRect& aRenderRect)
{
  if (![(ChildView*)mView preRender:mGLPresenter->GetNSOpenGLContext()]) {
    return;
  }
  mGLPresenter->BeginFrame(aRenderRect.Size());

  // Draw the result from the basic compositor.
  mBasicCompositorImage->Draw(mGLPresenter, nsIntPoint(0, 0));

  // DrawWindowOverlay doesn't do anything for non-GL, so it didn't paint
  // anything during the basic compositor transaction. Draw the overlay now.
  DrawWindowOverlay(mGLPresenter, aRenderRect);

  mGLPresenter->EndFrame();

  [(ChildView*)mView postRender:mGLPresenter->GetNSOpenGLContext()];
}

void
nsChildView::UpdateWindowDraggingRegion(const nsIntRegion& aRegion)
{
  if (mDraggableRegion != aRegion) {
    mDraggableRegion = aRegion;
    [(ChildView*)mView updateWindowDraggableState];
  }
}

#ifdef ACCESSIBILITY
already_AddRefed<a11y::Accessible>
nsChildView::GetDocumentAccessible()
{
  if (!mozilla::a11y::ShouldA11yBeEnabled())
    return nullptr;

  if (mAccessible) {
    nsRefPtr<a11y::Accessible> ret;
    CallQueryReferent(mAccessible.get(),
                      static_cast<a11y::Accessible**>(getter_AddRefs(ret)));
    return ret.forget();
  }

  // need to fetch the accessible anew, because it has gone away.
  // cache the accessible in our weak ptr
  nsRefPtr<a11y::Accessible> acc = GetRootAccessible();
  mAccessible = do_GetWeakReference(acc.get());

  return acc.forget();
}
#endif

// RectTextureImage implementation

RectTextureImage::~RectTextureImage()
{
  if (mTexture) {
    mGLContext->MakeCurrent();
    mGLContext->fDeleteTextures(1, &mTexture);
    mTexture = 0;
  }
}

nsIntSize
RectTextureImage::TextureSizeForSize(const nsIntSize& aSize)
{
  return nsIntSize(gfx::NextPowerOfTwo(aSize.width),
                   gfx::NextPowerOfTwo(aSize.height));
}

TemporaryRef<gfx::DrawTarget>
RectTextureImage::BeginUpdate(const nsIntSize& aNewSize,
                              const nsIntRegion& aDirtyRegion)
{
  MOZ_ASSERT(!mInUpdate, "Beginning update during update!");
  mUpdateRegion = aDirtyRegion;
  if (aNewSize != mUsedSize) {
    mUsedSize = aNewSize;
    mUpdateRegion = nsIntRect(nsIntPoint(0, 0), aNewSize);
  }

  if (mUpdateRegion.IsEmpty()) {
    return nullptr;
  }

  nsIntSize neededBufferSize = TextureSizeForSize(mUsedSize);
  if (!mUpdateDrawTarget || mBufferSize != neededBufferSize) {
    gfx::IntSize size(neededBufferSize.width, neededBufferSize.height);
    mUpdateDrawTarget =
      gfx::Factory::CreateDrawTarget(gfx::BackendType::COREGRAPHICS, size,
                                     gfx::SurfaceFormat::B8G8R8A8);
    mBufferSize = neededBufferSize;
  }

  mInUpdate = true;

  RefPtr<gfx::DrawTarget> drawTarget = mUpdateDrawTarget;
  return drawTarget;
}

#define NSFoundationVersionWithProperStrideSupportForSubtextureUpload NSFoundationVersionNumber10_6_3

static bool
CanUploadSubtextures()
{
  return NSFoundationVersionNumber >= NSFoundationVersionWithProperStrideSupportForSubtextureUpload;
}

void
RectTextureImage::EndUpdate(bool aKeepSurface)
{
  MOZ_ASSERT(mInUpdate, "Ending update while not in update");

  bool overwriteTexture = false;
  nsIntRegion updateRegion = mUpdateRegion;
  if (!mTexture || (mTextureSize != mBufferSize)) {
    overwriteTexture = true;
    mTextureSize = mBufferSize;
  }

  if (overwriteTexture || !CanUploadSubtextures()) {
    updateRegion = nsIntRect(nsIntPoint(0, 0), mTextureSize);
  }

  RefPtr<gfx::SourceSurface> snapshot = mUpdateDrawTarget->Snapshot();
  RefPtr<gfx::DataSourceSurface> dataSnapshot = snapshot->GetDataSurface();

  UploadSurfaceToTexture(mGLContext,
                         dataSnapshot,
                         updateRegion,
                         mTexture,
                         overwriteTexture,
                         updateRegion.GetBounds().TopLeft(),
                         false,
                         LOCAL_GL_TEXTURE0,
                         LOCAL_GL_TEXTURE_RECTANGLE_ARB);

  if (!aKeepSurface) {
    mUpdateDrawTarget = nullptr;
  }

  mInUpdate = false;
}

void
RectTextureImage::UpdateFromCGContext(const nsIntSize& aNewSize,
                                      const nsIntRegion& aDirtyRegion,
                                      CGContextRef aCGContext)
{
  gfx::IntSize size = gfx::IntSize(CGBitmapContextGetWidth(aCGContext),
                                   CGBitmapContextGetHeight(aCGContext));
  mBufferSize.SizeTo(size.width, size.height);
  RefPtr<gfx::DrawTarget> dt = BeginUpdate(aNewSize, aDirtyRegion);
  if (dt) {
    gfx::Rect rect(0, 0, size.width, size.height);
    gfxUtils::ClipToRegion(dt, GetUpdateRegion());
    RefPtr<gfx::SourceSurface> sourceSurface =
      dt->CreateSourceSurfaceFromData(static_cast<uint8_t *>(CGBitmapContextGetData(aCGContext)),
                                      size,
                                      CGBitmapContextGetBytesPerRow(aCGContext),
                                      gfx::SurfaceFormat::B8G8R8A8);
    dt->DrawSurface(sourceSurface, rect, rect,
                    gfx::DrawSurfaceOptions(),
                    gfx::DrawOptions(1.0, gfx::CompositionOp::OP_SOURCE));
    dt->PopClip();
    EndUpdate();
  }
}

void
RectTextureImage::UpdateFromDrawTarget(const nsIntSize& aNewSize,
                                       const nsIntRegion& aDirtyRegion,
                                       gfx::DrawTarget* aFromDrawTarget)
{
  mUpdateDrawTarget = aFromDrawTarget;
  mBufferSize.SizeTo(aFromDrawTarget->GetSize().width, aFromDrawTarget->GetSize().height);
  RefPtr<gfx::DrawTarget> drawTarget = BeginUpdate(aNewSize, aDirtyRegion);
  if (drawTarget) {
    if (drawTarget != aFromDrawTarget) {
      RefPtr<gfx::SourceSurface> source = aFromDrawTarget->Snapshot();
      gfx::Rect rect(0, 0, aFromDrawTarget->GetSize().width, aFromDrawTarget->GetSize().height);
      gfxUtils::ClipToRegion(drawTarget, GetUpdateRegion());
      drawTarget->DrawSurface(source, rect, rect,
                              gfx::DrawSurfaceOptions(),
                              gfx::DrawOptions(1.0, gfx::CompositionOp::OP_SOURCE));
      drawTarget->PopClip();
    }
    EndUpdate();
  }
  mUpdateDrawTarget = nullptr;
}

void
RectTextureImage::Draw(GLManager* aManager,
                       const nsIntPoint& aLocation,
                       const Matrix4x4& aTransform)
{
  ShaderProgramOGL* program = aManager->GetProgram(LOCAL_GL_TEXTURE_RECTANGLE_ARB,
                                                   gfx::SurfaceFormat::R8G8B8A8);

  aManager->gl()->fBindTexture(LOCAL_GL_TEXTURE_RECTANGLE_ARB, mTexture);

  aManager->ActivateProgram(program);
  program->SetProjectionMatrix(aManager->GetProjMatrix());
  program->SetLayerTransform(Matrix4x4(aTransform).PostTranslate(aLocation.x, aLocation.y, 0));
  program->SetTextureTransform(gfx::Matrix4x4());
  program->SetRenderOffset(nsIntPoint(0, 0));
  program->SetTexCoordMultiplier(mUsedSize.width, mUsedSize.height);
  program->SetTextureUnit(0);

  aManager->BindAndDrawQuad(program,
                            gfx::Rect(0.0, 0.0, mUsedSize.width, mUsedSize.height),
                            gfx::Rect(0.0, 0.0, 1.0f, 1.0f));

  aManager->gl()->fBindTexture(LOCAL_GL_TEXTURE_RECTANGLE_ARB, 0);
}

// GLPresenter implementation

GLPresenter::GLPresenter(GLContext* aContext)
 : mGLContext(aContext)
{
  mGLContext->MakeCurrent();
  ShaderConfigOGL config;
  config.SetTextureTarget(LOCAL_GL_TEXTURE_RECTANGLE_ARB);
  mRGBARectProgram = new ShaderProgramOGL(mGLContext,
    ProgramProfileOGL::GetProfileFor(config));

  // Create mQuadVBO.
  mGLContext->fGenBuffers(1, &mQuadVBO);
  mGLContext->fBindBuffer(LOCAL_GL_ARRAY_BUFFER, mQuadVBO);

  // 1 quad, with the number of the quad (vertexID) encoded in w.
  GLfloat vertices[] = {
    0.0f, 0.0f, 0.0f, 0.0f,
    1.0f, 0.0f, 0.0f, 0.0f,
    0.0f, 1.0f, 0.0f, 0.0f,
    1.0f, 0.0f, 0.0f, 0.0f,
    0.0f, 1.0f, 0.0f, 0.0f,
    1.0f, 1.0f, 0.0f, 0.0f,
  };
  HeapCopyOfStackArray<GLfloat> verticesOnHeap(vertices);
  mGLContext->fBufferData(LOCAL_GL_ARRAY_BUFFER,
                          verticesOnHeap.ByteLength(),
                          verticesOnHeap.Data(),
                          LOCAL_GL_STATIC_DRAW);
   mGLContext->fBindBuffer(LOCAL_GL_ARRAY_BUFFER, 0);
}

GLPresenter::~GLPresenter()
{
  if (mQuadVBO) {
    mGLContext->MakeCurrent();
    mGLContext->fDeleteBuffers(1, &mQuadVBO);
    mQuadVBO = 0;
  }
}

void
GLPresenter::BindAndDrawQuad(ShaderProgramOGL *aProgram,
                             const gfx::Rect& aLayerRect,
                             const gfx::Rect& aTextureRect)
{
  mGLContext->MakeCurrent();

  gfx::Rect layerRects[4];
  gfx::Rect textureRects[4];

  layerRects[0] = aLayerRect;
  textureRects[0] = aTextureRect;

  aProgram->SetLayerRects(layerRects);
  aProgram->SetTextureRects(textureRects);

  const GLuint coordAttribIndex = 0;

  mGLContext->fBindBuffer(LOCAL_GL_ARRAY_BUFFER, mQuadVBO);
  mGLContext->fVertexAttribPointer(coordAttribIndex, 4,
                                   LOCAL_GL_FLOAT, LOCAL_GL_FALSE, 0,
                                   (GLvoid*)0);
  mGLContext->fEnableVertexAttribArray(coordAttribIndex);
  mGLContext->fDrawArrays(LOCAL_GL_TRIANGLES, 0, 6);
  mGLContext->fDisableVertexAttribArray(coordAttribIndex);
}

void
GLPresenter::BeginFrame(nsIntSize aRenderSize)
{
  mGLContext->MakeCurrent();

  mGLContext->fViewport(0, 0, aRenderSize.width, aRenderSize.height);

  // Matrix to transform (0, 0, width, height) to viewport space (-1.0, 1.0,
  // 2, 2) and flip the contents.
  gfx::Matrix viewMatrix = gfx::Matrix::Translation(-1.0, 1.0);
  viewMatrix.PreScale(2.0f / float(aRenderSize.width),
                      2.0f / float(aRenderSize.height));
  viewMatrix.PreScale(1.0f, -1.0f);

  gfx::Matrix4x4 matrix3d = gfx::Matrix4x4::From2D(viewMatrix);
  matrix3d._33 = 0.0f;

  // set the projection matrix for the next time the program is activated
  mProjMatrix = matrix3d;

  // Default blend function implements "OVER"
  mGLContext->fBlendFuncSeparate(LOCAL_GL_ONE, LOCAL_GL_ONE_MINUS_SRC_ALPHA,
                                 LOCAL_GL_ONE, LOCAL_GL_ONE);
  mGLContext->fEnable(LOCAL_GL_BLEND);

  mGLContext->fClearColor(0.0, 0.0, 0.0, 0.0);
  mGLContext->fClear(LOCAL_GL_COLOR_BUFFER_BIT | LOCAL_GL_DEPTH_BUFFER_BIT);

  mGLContext->fEnable(LOCAL_GL_TEXTURE_RECTANGLE_ARB);
}

void
GLPresenter::EndFrame()
{
  mGLContext->SwapBuffers();
  mGLContext->fBindBuffer(LOCAL_GL_ARRAY_BUFFER, 0);
}

#pragma mark -

@implementation ChildView

// globalDragPboard is non-null during native drag sessions that did not originate
// in our native NSView (it is set in |draggingEntered:|). It is unset when the
// drag session ends for this view, either with the mouse exiting or when a drop
// occurs in this view.
NSPasteboard* globalDragPboard = nil;

// gLastDragView and gLastDragMouseDownEvent are used to communicate information
// to the drag service during drag invocation (starting a drag in from the view).
// gLastDragView is only non-null while mouseDragged is on the call stack.
NSView* gLastDragView = nil;
NSEvent* gLastDragMouseDownEvent = nil;

+ (void)initialize
{
  static BOOL initialized = NO;

  if (!initialized) {
    // Inform the OS about the types of services (from the "Services" menu)
    // that we can handle.

    NSArray *sendTypes = [[NSArray alloc] initWithObjects:NSStringPboardType,NSHTMLPboardType,nil];
    NSArray *returnTypes = [[NSArray alloc] initWithObjects:NSStringPboardType,NSHTMLPboardType,nil];

    [NSApp registerServicesMenuSendTypes:sendTypes returnTypes:returnTypes];

    [sendTypes release];
    [returnTypes release];

    initialized = YES;
  }
}

+ (void)registerViewForDraggedTypes:(NSView*)aView
{
  [aView registerForDraggedTypes:[NSArray arrayWithObjects:NSFilenamesPboardType,
                                                           NSStringPboardType,
                                                           NSHTMLPboardType,
                                                           NSURLPboardType,
                                                           NSFilesPromisePboardType,
                                                           kWildcardPboardType,
                                                           kCorePboardType_url,
                                                           kCorePboardType_urld,
                                                           kCorePboardType_urln,
                                                           nil]];
}

// initWithFrame:goannaChild:
- (id)initWithFrame:(NSRect)inFrame goannaChild:(nsChildView*)inChild
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_NIL;

  if ((self = [super initWithFrame:inFrame])) {
    mGoannaChild = inChild;
    mPendingDisplay = NO;
    mBlockedLastMouseDown = NO;
    mExpectingWheelStop = NO;

    mLastMouseDownEvent = nil;
    mLastKeyDownEvent = nil;
    mClickThroughMouseDownEvent = nil;
    mDragService = nullptr;

    mGestureState = eGestureState_None;
    mCumulativeMagnification = 0.0;
    mCumulativeRotation = 0.0;

    // We can't call forceRefreshOpenGL here because, in order to work around
    // the bug, it seems we need to have a draw already happening. Therefore,
    // we call it in drawRect:inContext:, when we know that a draw is in
    // progress.
    mDidForceRefreshOpenGL = NO;

    [self setFocusRingType:NSFocusRingTypeNone];

#ifdef __LP64__
    mCancelSwipeAnimation = nil;
    mCurrentSwipeDir = 0;
#endif

    mTopLeftCornerMask = NULL;
  }

  // register for things we'll take from other applications
  [ChildView registerViewForDraggedTypes:self];

  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(systemMetricsChanged)
                                               name:NSControlTintDidChangeNotification
                                             object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(systemMetricsChanged)
                                               name:NSSystemColorsDidChangeNotification
                                             object:nil];
  // TODO: replace the string with the constant once we build with the 10.7 SDK
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(scrollbarSystemMetricChanged)
                                               name:@"NSPreferredScrollerStyleDidChangeNotification"
                                             object:nil];
  [[NSDistributedNotificationCenter defaultCenter] addObserver:self
                                                      selector:@selector(systemMetricsChanged)
                                                          name:@"AppleAquaScrollBarVariantChanged"
                                                        object:nil
                                            suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(_surfaceNeedsUpdate:)
                                               name:NSViewGlobalFrameDidChangeNotification
                                             object:self];

  return self;

  NS_OBJC_END_TRY_ABORT_BLOCK_NIL;
}

// ComplexTextInputPanel's interpretKeyEvent hack won't work without this.
// It makes calls to +[NSTextInputContext currentContext], deep in system
// code, return the appropriate context.
- (NSTextInputContext *)inputContext
{
  NSTextInputContext* pluginContext = NULL;
  if (mGoannaChild && mGoannaChild->IsPluginFocused()) {
    ComplexTextInputPanel* ctiPanel =
      ComplexTextInputPanel::GetSharedComplexTextInputPanel();
    if (ctiPanel) {
      pluginContext = (NSTextInputContext*) ctiPanel->GetInputContext();
    }
  }
  if (pluginContext) {
    return pluginContext;
  } else {
    return [super inputContext];
  }
}

- (void)installTextInputHandler:(TextInputHandler*)aHandler
{
  mTextInputHandler = aHandler;
}

- (void)uninstallTextInputHandler
{
  mTextInputHandler = nullptr;
}

// Work around bug 603134.
// OS X has a bug that causes new OpenGL windows to only paint once or twice,
// then stop painting altogether. By clearing the drawable from the GL context,
// and then resetting the view to ourselves, we convince OS X to start updating
// again.
// This can cause a flash in new windows - bug 631339 - but it's very hard to
// fix that while maintaining this workaround.
- (void)forceRefreshOpenGL
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK;

  [mGLContext clearDrawable];
  [self updateGLContext];

  NS_OBJC_END_TRY_ABORT_BLOCK;
}

- (void)setGLContext:(NSOpenGLContext *)aGLContext
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK;

  mGLContext = aGLContext;
  [mGLContext retain];

  NS_OBJC_END_TRY_ABORT_BLOCK;
}

- (bool)preRender:(NSOpenGLContext *)aGLContext
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_RETURN;

  if (![self window] ||
      ([[self window] isKindOfClass:[BaseWindow class]] &&
       ![(BaseWindow*)[self window] isVisibleOrBeingShown])) {
    // Before the window is shown, our GL context's front FBO is not
    // framebuffer complete, so we refuse to render.
    return false;
  }

  if (!mGLContext) {
    [self setGLContext:aGLContext];
    [self updateGLContext];
  }

  CGLLockContext((CGLContextObj)[aGLContext CGLContextObj]);

  return true;

  NS_OBJC_END_TRY_ABORT_BLOCK_RETURN(false);
}

- (void)postRender:(NSOpenGLContext *)aGLContext
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK;

  CGLUnlockContext((CGLContextObj)[aGLContext CGLContextObj]);

  NS_OBJC_END_TRY_ABORT_BLOCK;
}

- (void)dealloc
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK;

  [mGLContext release];
  [mPendingDirtyRects release];
  [mLastMouseDownEvent release];
  [mLastKeyDownEvent release];
  [mClickThroughMouseDownEvent release];
  CGImageRelease(mTopLeftCornerMask);
  ChildViewMouseTracker::OnDestroyView(self);

  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [[NSDistributedNotificationCenter defaultCenter] removeObserver:self];

  [super dealloc];

  NS_OBJC_END_TRY_ABORT_BLOCK;
}

- (void)widgetDestroyed
{
  if (mTextInputHandler) {
    mTextInputHandler->OnDestroyWidget(mGoannaChild);
    mTextInputHandler = nullptr;
  }
  mGoannaChild = nullptr;

  // Just in case we're destroyed abruptly and missed the draggingExited
  // or performDragOperation message.
  NS_IF_RELEASE(mDragService);
}

// mozView method, return our goanna child view widget. Note this does not AddRef.
- (nsIWidget*) widget
{
  return static_cast<nsIWidget*>(mGoannaChild);
}

- (void)systemMetricsChanged
{
  if (mGoannaChild)
    mGoannaChild->NotifyThemeChanged();
}

- (void)scrollbarSystemMetricChanged
{
  [self systemMetricsChanged];

  if (mGoannaChild) {
    nsIWidgetListener* listener = mGoannaChild->GetWidgetListener();
    if (listener) {
      listener->GetPresShell()->ReconstructFrames();
    }
  }
}

- (void)setNeedsPendingDisplay
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK;

  mPendingFullDisplay = YES;
  if (!mPendingDisplay) {
    [self performSelector:@selector(processPendingRedraws) withObject:nil afterDelay:0];
    mPendingDisplay = YES;
  }

  NS_OBJC_END_TRY_ABORT_BLOCK;
}

- (void)setNeedsPendingDisplayInRect:(NSRect)invalidRect
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK;

  if (!mPendingDirtyRects)
    mPendingDirtyRects = [[NSMutableArray alloc] initWithCapacity:1];
  [mPendingDirtyRects addObject:[NSValue valueWithRect:invalidRect]];
  if (!mPendingDisplay) {
    [self performSelector:@selector(processPendingRedraws) withObject:nil afterDelay:0];
    mPendingDisplay = YES;
  }

  NS_OBJC_END_TRY_ABORT_BLOCK;
}

// Clears the queue of any pending invalides
- (void)processPendingRedraws
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK;

  if (mPendingFullDisplay) {
    [self setNeedsDisplay:YES];
  }
  else if (mPendingDirtyRects) {
    unsigned int count = [mPendingDirtyRects count];
    for (unsigned int i = 0; i < count; ++i) {
      [self setNeedsDisplayInRect:[[mPendingDirtyRects objectAtIndex:i] rectValue]];
    }
  }
  mPendingFullDisplay = NO;
  mPendingDisplay = NO;
  [mPendingDirtyRects release];
  mPendingDirtyRects = nil;

  NS_OBJC_END_TRY_ABORT_BLOCK;
}

- (void)setNeedsDisplayInRect:(NSRect)aRect
{
  if (![self isUsingOpenGL]) {
    [super setNeedsDisplayInRect:aRect];
    return;
  }

  if ([[self window] isVisible] && [self isUsingMainThreadOpenGL]) {
    // Draw without calling drawRect. This prevent us from
    // needing to access the normal window buffer surface unnecessarily, so we
    // waste less time synchronizing the two surfaces. (These synchronizations
    // show up in a profiler as CGSDeviceLock / _CGSLockWindow /
    // _CGSSynchronizeWindowBackingStore.) It also means that Cocoa doesn't
    // have any potentially expensive invalid rect management for us.
    if (!mWaitingForPaint) {
      mWaitingForPaint = YES;
      // Use NSRunLoopCommonModes instead of the default NSDefaultRunLoopMode
      // so that the timer also fires while a native menu is open.
      [self performSelector:@selector(drawUsingOpenGLCallback)
                 withObject:nil
                 afterDelay:0
                    inModes:[NSArray arrayWithObject:NSRunLoopCommonModes]];
    }
  }
}

- (NSString*)description
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_NIL;

  return [NSString stringWithFormat:@"ChildView %p, goanna child %p, frame %@", self, mGoannaChild, NSStringFromRect([self frame])];

  NS_OBJC_END_TRY_ABORT_BLOCK_NIL;
}

// Make the origin of this view the topLeft corner (goanna origin) rather
// than the bottomLeft corner (standard cocoa origin).
- (BOOL)isFlipped
{
  return YES;
}

- (BOOL)isOpaque
{
  return [[self window] isOpaque];
}

- (void)sendFocusEvent:(uint32_t)eventType
{
  if (!mGoannaChild)
    return;

  nsEventStatus status = nsEventStatus_eIgnore;
  WidgetGUIEvent focusGuiEvent(true, eventType, mGoannaChild);
  focusGuiEvent.time = PR_IntervalNow();
  mGoannaChild->DispatchEvent(&focusGuiEvent, status);
}

// We accept key and mouse events, so don't keep passing them up the chain. Allow
// this to be a 'focused' widget for event dispatch.
- (BOOL)acceptsFirstResponder
{
  return YES;
}

// Accept mouse down events on background windows
- (BOOL)acceptsFirstMouse:(NSEvent*)aEvent
{
  if (![[self window] isKindOfClass:[PopupWindow class]]) {
    // We rely on this function to tell us that the mousedown was on a
    // background window. Inside mouseDown we can't tell whether we were
    // inactive because at that point we've already been made active.
    // Unfortunately, acceptsFirstMouse is called for PopupWindows even when
    // their parent window is active, so ignore this on them for now.
    mClickThroughMouseDownEvent = [aEvent retain];
  }
  return YES;
}

- (void)scrollRect:(NSRect)aRect by:(NSSize)offset
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK;

  // Update any pending dirty rects to reflect the new scroll position
  if (mPendingDirtyRects) {
    unsigned int count = [mPendingDirtyRects count];
    for (unsigned int i = 0; i < count; ++i) {
      NSRect oldRect = [[mPendingDirtyRects objectAtIndex:i] rectValue];
      NSRect newRect = NSOffsetRect(oldRect, offset.width, offset.height);
      [mPendingDirtyRects replaceObjectAtIndex:i
                                    withObject:[NSValue valueWithRect:newRect]];
    }
  }
  [super scrollRect:aRect by:offset];

  NS_OBJC_END_TRY_ABORT_BLOCK;
}

- (BOOL)mouseDownCanMoveWindow
{
  // Return YES so that _regionForOpaqueDescendants gets called, where the
  // actual draggable region will be assembled.
  return YES;
}

-(void)updateGLContext
{
  if (mGLContext) {
    CGLLockContext((CGLContextObj)[mGLContext CGLContextObj]);
    [mGLContext setView:self];
    [mGLContext update];
    CGLUnlockContext((CGLContextObj)[mGLContext CGLContextObj]);
  }
}

- (void)_surfaceNeedsUpdate:(NSNotification*)notification
{
   [self updateGLContext];
}

- (BOOL)wantsBestResolutionOpenGLSurface
{
  return nsCocoaUtils::HiDPIEnabled() ? YES : NO;
}

- (void)viewDidChangeBackingProperties
{
  [super viewDidChangeBackingProperties];
  if (mGoannaChild) {
    // actually, it could be the color space that's changed,
    // but we can't tell the difference here except by retrieving
    // the backing scale factor and comparing to the old value
    mGoannaChild->BackingScaleFactorChanged();
  }
}

- (BOOL)isCoveringTitlebar
{
  return [[self window] isKindOfClass:[BaseWindow class]] &&
         [(BaseWindow*)[self window] mainChildView] == self &&
         [(BaseWindow*)[self window] drawsContentsIntoWindowFrame];
}

- (NSColor*)vibrancyFillColorForThemeGeometryType:(nsITheme::ThemeGeometryType)aThemeGeometryType
{
  if (!mGoannaChild) {
    return [NSColor whiteColor];
  }
  return mGoannaChild->VibrancyFillColorForThemeGeometryType(aThemeGeometryType);
}

- (NSColor*)vibrancyFontSmoothingBackgroundColorForThemeGeometryType:(nsITheme::ThemeGeometryType)aThemeGeometryType
{
  if (!mGoannaChild) {
    return [NSColor clearColor];
  }
  return mGoannaChild->VibrancyFontSmoothingBackgroundColorForThemeGeometryType(aThemeGeometryType);
}

- (nsIntRegion)nativeDirtyRegionWithBoundingRect:(NSRect)aRect
{
  nsIntRect boundingRect = mGoannaChild->CocoaPointsToDevPixels(aRect);
  const NSRect *rects;
  NSInteger count;
  [self getRectsBeingDrawn:&rects count:&count];

  if (count > MAX_RECTS_IN_REGION) {
    return boundingRect;
  }

  nsIntRegion region;
  for (NSInteger i = 0; i < count; ++i) {
    region.Or(region, mGoannaChild->CocoaPointsToDevPixels(rects[i]));
  }
  region.And(region, boundingRect);
  return region;
}

// The display system has told us that a portion of our view is dirty. Tell
// goanna to paint it
- (void)drawRect:(NSRect)aRect
{
  CGContextRef cgContext = (CGContextRef)[[NSGraphicsContext currentContext] graphicsPort];
  [self drawRect:aRect inContext:cgContext];

  // If we're a transparent window and our contents have changed, we need
  // to make sure the shadow is updated to the new contents.
  if ([[self window] isKindOfClass:[BaseWindow class]]) {
    [(BaseWindow*)[self window] deferredInvalidateShadow];
  }
}

- (void)drawRect:(NSRect)aRect inContext:(CGContextRef)aContext
{
  if (!mGoannaChild || !mGoannaChild->IsVisible())
    return;

#ifdef DEBUG_UPDATE
  nsIntRect goannaBounds;
  mGoannaChild->GetBounds(goannaBounds);

  fprintf (stderr, "---- Update[%p][%p] [%f %f %f %f] cgc: %p\n  goanna bounds: [%d %d %d %d]\n",
           self, mGoannaChild,
           aRect.origin.x, aRect.origin.y, aRect.size.width, aRect.size.height, aContext,
           goannaBounds.x, goannaBounds.y, goannaBounds.width, goannaBounds.height);

  CGAffineTransform xform = CGContextGetCTM(aContext);
  fprintf (stderr, "  xform in: [%f %f %f %f %f %f]\n", xform.a, xform.b, xform.c, xform.d, xform.tx, xform.ty);
#endif

  if ([self isUsingOpenGL]) {
    // For Goanna-initiated repaints in OpenGL mode, drawUsingOpenGL is
    // directly called from a delayed perform callback - without going through
    // drawRect.
    // Paints that come through here are triggered by something that Cocoa
    // controls, for example by window resizing or window focus changes.

    // Since this view is usually declared as opaque, the window's pixel
    // buffer may now contain garbage which we need to prevent from reaching
    // the screen. The only place where garbage can show is in the window
    // corners and the vibrant regions of the window - the rest of the window
    // is covered by opaque content in our OpenGL surface.
    // So we need to clear the pixel buffer contents in these areas.
    mGoannaChild->ClearVibrantAreas();
    [self clearCorners];

    // Do GL composition and return.
    [self drawUsingOpenGL];
    return;
  }

  PROFILER_LABEL("ChildView", "drawRect",
    js::ProfileEntry::Category::GRAPHICS);

  // The CGContext that drawRect supplies us with comes with a transform that
  // scales one user space unit to one Cocoa point, which can consist of
  // multiple dev pixels. But Goanna expects its supplied context to be scaled
  // to device pixels, so we need to reverse the scaling.
  double scale = mGoannaChild->BackingScaleFactor();
  CGContextSaveGState(aContext);
  CGContextScaleCTM(aContext, 1.0 / scale, 1.0 / scale);

  NSSize viewSize = [self bounds].size;
  nsIntSize backingSize(viewSize.width * scale, viewSize.height * scale);

  CGContextSaveGState(aContext);

  nsIntRegion region = [self nativeDirtyRegionWithBoundingRect:aRect];

  // Create Cairo objects.
  nsRefPtr<gfxQuartzSurface> targetSurface;

  nsRefPtr<gfxContext> targetContext;
  if (gfxPlatform::GetPlatform()->SupportsAzureContentForType(gfx::BackendType::COREGRAPHICS)) {
    RefPtr<gfx::DrawTarget> dt =
      gfx::Factory::CreateDrawTargetForCairoCGContext(aContext,
                                                      gfx::IntSize(backingSize.width,
                                                                   backingSize.height));
    dt->AddUserData(&gfxContext::sDontUseAsSourceKey, dt, nullptr);
    targetContext = new gfxContext(dt);
  } else if (gfxPlatform::GetPlatform()->SupportsAzureContentForType(gfx::BackendType::CAIRO)) {
    // This is dead code unless you mess with prefs, but keep it around for
    // debugging.
    targetSurface = new gfxQuartzSurface(aContext, backingSize);
    targetSurface->SetAllowUseAsSource(false);
    RefPtr<gfx::DrawTarget> dt =
      gfxPlatform::GetPlatform()->CreateDrawTargetForSurface(targetSurface,
                                                             gfx::IntSize(backingSize.width,
                                                                          backingSize.height));
    dt->AddUserData(&gfxContext::sDontUseAsSourceKey, dt, nullptr);
    targetContext = new gfxContext(dt);
  } else {
    MOZ_ASSERT_UNREACHABLE("COREGRAPHICS is the only supported backed");
  }

  // Set up the clip region.
  nsIntRegionRectIterator iter(region);
  targetContext->NewPath();
  for (;;) {
    const nsIntRect* r = iter.Next();
    if (!r)
      break;
    targetContext->Rectangle(gfxRect(r->x, r->y, r->width, r->height));
  }
  targetContext->Clip();

  nsAutoRetainCocoaObject kungFuDeathGrip(self);
  bool painted = false;
  if (mGoannaChild->GetLayerManager()->GetBackendType() == LayersBackend::LAYERS_BASIC) {
    nsBaseWidget::AutoLayerManagerSetup
      setupLayerManager(mGoannaChild, targetContext, BufferMode::BUFFER_NONE);
    painted = mGoannaChild->PaintWindow(region);
  } else if (mGoannaChild->GetLayerManager()->GetBackendType() == LayersBackend::LAYERS_CLIENT) {
    // We only need this so that we actually get DidPaintWindow fired
    painted = mGoannaChild->PaintWindow(region);
  }

  targetContext = nullptr;
  targetSurface = nullptr;

  CGContextRestoreGState(aContext);

  // Undo the scale transform so that from now on the context is in
  // CocoaPoints again.
  CGContextRestoreGState(aContext);

  if (!painted && [self isOpaque]) {
    // Goanna refused to draw, but we've claimed to be opaque, so we have to
    // draw something--fill with white.
    CGContextSetRGBFillColor(aContext, 1, 1, 1, 1);
    CGContextFillRect(aContext, NSRectToCGRect(aRect));
  }

  if ([self isCoveringTitlebar]) {
    [self drawTitleString];
    [self drawTitlebarHighlight];
    [self maskTopCornersInContext:aContext];
  }

#ifdef DEBUG_UPDATE
  fprintf (stderr, "---- update done ----\n");

#if 0
  CGContextSetRGBStrokeColor (aContext,
                            ((((unsigned long)self) & 0xff)) / 255.0,
                            ((((unsigned long)self) & 0xff00) >> 8) / 255.0,
                            ((((unsigned long)self) & 0xff0000) >> 16) / 255.0,
                            0.5);
#endif
  CGContextSetRGBStrokeColor(aContext, 1, 0, 0, 0.8);
  CGContextSetLineWidth(aContext, 4.0);
  CGContextStrokeRect(aContext, NSRectToCGRect(aRect));
#endif
}

- (BOOL)isUsingMainThreadOpenGL
{
  if (!mGoannaChild || ![self window])
    return NO;

  return mGoannaChild->GetLayerManager(nullptr)->GetBackendType() == mozilla::layers::LayersBackend::LAYERS_OPENGL;
}

- (BOOL)isUsingOpenGL
{
  if (!mGoannaChild || ![self window])
    return NO;

  return mGLContext || mUsingOMTCompositor || [self isUsingMainThreadOpenGL];
}

- (void)drawUsingOpenGL
{
  PROFILER_LABEL("ChildView", "drawUsingOpenGL",
    js::ProfileEntry::Category::GRAPHICS);

  if (![self isUsingOpenGL] || !mGoannaChild->IsVisible())
    return;

  mWaitingForPaint = NO;

  nsIntRect goannaBounds;
  mGoannaChild->GetBounds(goannaBounds);
  nsIntRegion region(goannaBounds);

  mGoannaChild->PaintWindow(region);

  // Force OpenGL to refresh the very first time we draw. This works around a
  // Mac OS X bug that stops windows updating on OS X when we use OpenGL.
  if (!mDidForceRefreshOpenGL) {
    [self performSelector:@selector(forceRefreshOpenGL) withObject:nil afterDelay:0];
    mDidForceRefreshOpenGL = YES;
  }
}

// Called asynchronously after setNeedsDisplay in order to avoid entering the
// normal drawing machinery.
- (void)drawUsingOpenGLCallback
{
  if (mWaitingForPaint) {
    [self drawUsingOpenGL];
  }
}

- (BOOL)hasRoundedBottomCorners
{
  return [[self window] respondsToSelector:@selector(bottomCornerRounded)] &&
  [[self window] bottomCornerRounded];
}

- (CGFloat)cornerRadius
{
  NSView* frameView = [[[self window] contentView] superview];
  if (!frameView || ![frameView respondsToSelector:@selector(roundedCornerRadius)])
    return 4.0f;
  return [frameView roundedCornerRadius];
}

// Accelerated windows have two NSSurfaces:
//  (1) The window's pixel buffer in the back and
//  (2) the OpenGL view in the front.
// These two surfaces are composited by the window manager. Drawing into the
// CGContext which is provided by drawRect ends up in (1).
// When our window has rounded corners, the OpenGL view has transparent pixels
// in the corners. In these places the contents of the window's pixel buffer
// can show through. So we need to make sure that the pixel buffer is
// transparent in the corners so that no garbage reaches the screen.
// The contents of the pixel buffer in the rest of the window don't matter
// because they're covered by opaque pixels of the OpenGL context.
// Making the corners transparent works even though our window is
// declared "opaque" (in the NSWindow's isOpaque method).
- (void)clearCorners
{
  CGFloat radius = [self cornerRadius];
  CGFloat w = [self bounds].size.width, h = [self bounds].size.height;
  [[NSColor clearColor] set];

  if ([self isCoveringTitlebar]) {
    NSRectFill(NSMakeRect(0, 0, radius, radius));
    NSRectFill(NSMakeRect(w - radius, 0, radius, radius));
  }

  if ([self hasRoundedBottomCorners]) {
    NSRectFill(NSMakeRect(0, h - radius, radius, radius));
    NSRectFill(NSMakeRect(w - radius, h - radius, radius, radius));
  }
}

// This is the analog of nsChildView::MaybeDrawRoundedCorners for CGContexts.
// We only need to mask the top corners here because Cocoa does the masking
// for the window's bottom corners automatically (starting with 10.7).
- (void)maskTopCornersInContext:(CGContextRef)aContext
{
  CGFloat radius = [self cornerRadius];
  int32_t devPixelCornerRadius = mGoannaChild->CocoaPointsToDevPixels(radius);

  // First make sure that mTopLeftCornerMask is set up.
  if (!mTopLeftCornerMask ||
      int32_t(CGImageGetWidth(mTopLeftCornerMask)) != devPixelCornerRadius) {
    CGImageRelease(mTopLeftCornerMask);
    CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
    CGContextRef imgCtx = CGBitmapContextCreate(NULL,
                                                devPixelCornerRadius,
                                                devPixelCornerRadius,
                                                8, devPixelCornerRadius * 4,
                                                rgb, kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(rgb);
    DrawTopLeftCornerMask(imgCtx, devPixelCornerRadius);
    mTopLeftCornerMask = CGBitmapContextCreateImage(imgCtx);
    CGContextRelease(imgCtx);
  }

  // kCGBlendModeDestinationIn is the secret sauce which allows us to erase
  // already painted pixels. It's defined as R = D * Sa: multiply all channels
  // of the destination pixel with the alpha of the source pixel. In our case,
  // the source is mTopLeftCornerMask.
  CGContextSaveGState(aContext);
  CGContextSetBlendMode(aContext, kCGBlendModeDestinationIn);

  CGRect destRect = CGRectMake(0, 0, radius, radius);

  // Erase the top left corner...
  CGContextDrawImage(aContext, destRect, mTopLeftCornerMask);

  // ... and the top right corner.
  CGContextTranslateCTM(aContext, [self bounds].size.width, 0);
  CGContextScaleCTM(aContext, -1, 1);
  CGContextDrawImage(aContext, destRect, mTopLeftCornerMask);

  CGContextRestoreGState(aContext);
}

- (void)drawTitleString
{
  BaseWindow* window = (BaseWindow*)[self window];
  if (![window wantsTitleDrawn]) {
    return;
  }

  NSView* frameView = [[window contentView] superview];
  if (![frameView respondsToSelector:@selector(_drawTitleBar:)]) {
    return;
  }

  NSGraphicsContext* oldContext = [NSGraphicsContext currentContext];
  CGContextRef ctx = (CGContextRef)[oldContext graphicsPort];
  CGContextSaveGState(ctx);
  if ([oldContext isFlipped] != [frameView isFlipped]) {
    CGContextTranslateCTM(ctx, 0, [self bounds].size.height);
    CGContextScaleCTM(ctx, 1, -1);
  }
  [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithGraphicsPort:ctx flipped:[frameView isFlipped]]];
  [frameView _drawTitleBar:[frameView bounds]];
  CGContextRestoreGState(ctx);
  [NSGraphicsContext setCurrentContext:oldContext];
}

- (void)drawTitlebarHighlight
{
  DrawTitlebarHighlight([self bounds].size, [self cornerRadius],
                        mGoannaChild->DevPixelsToCocoaPoints(1));
}

- (void)releaseWidgets:(NSArray*)aWidgetArray
{
  if (!aWidgetArray) {
    return;
  }
  NSInteger count = [aWidgetArray count];
  for (NSInteger i = 0; i < count; ++i) {
    NSNumber* pointer = (NSNumber*) [aWidgetArray objectAtIndex:i];
    nsIWidget* widget = (nsIWidget*) [pointer unsignedIntegerValue];
    NS_RELEASE(widget);
  }
}

- (void)viewWillDraw
{
  if (mGoannaChild) {
    // The OS normally *will* draw our NSWindow, no matter what we do here.
    // But Goanna can delete our parent widget(s) (along with mGoannaChild)
    // while processing a paint request, which closes our NSWindow and
    // makes the OS throw an NSInternalInconsistencyException assertion when
    // it tries to draw it.  Sometimes the OS also aborts the browser process.
    // So we need to retain our parent(s) here and not release it/them until
    // the next time through the main thread's run loop.  When we do this we
    // also need to retain and release mGoannaChild, which holds a strong
    // reference to us (otherwise we might have been deleted by the time
    // releaseWidgets: is called on us).  See bug 550392.
    nsIWidget* parent = mGoannaChild->GetParent();
    if (parent) {
      NSMutableArray* widgetArray = [NSMutableArray arrayWithCapacity:3];
      while (parent) {
        NS_ADDREF(parent);
        [widgetArray addObject:[NSNumber numberWithUnsignedInteger:(NSUInteger)parent]];
        parent = parent->GetParent();
      }
      NS_ADDREF(mGoannaChild);
      [widgetArray addObject:[NSNumber numberWithUnsignedInteger:(NSUInteger)mGoannaChild]];
      [self performSelector:@selector(releaseWidgets:)
                 withObject:widgetArray
                 afterDelay:0];
    }

    if ([self isUsingOpenGL]) {
      if (mGoannaChild->GetLayerManager()->GetBackendType() == LayersBackend::LAYERS_CLIENT) {
        ClientLayerManager *manager = static_cast<ClientLayerManager*>(mGoannaChild->GetLayerManager());
        manager->AsShadowForwarder()->WindowOverlayChanged();
      }
    }

    mGoannaChild->WillPaintWindow();
  }
  [super viewWillDraw];
}

#if USE_CLICK_HOLD_CONTEXTMENU
//
// -clickHoldCallback:
//
// called from a timer two seconds after a mouse down to see if we should display
// a context menu (click-hold). |anEvent| is the original mouseDown event. If we're
// still in that mouseDown by this time, put up the context menu, otherwise just
// fuhgeddaboutit. |anEvent| has been retained by the OS until after this callback
// fires so we're ok there.
//
// This code currently messes in a bunch of edge cases (bugs 234751, 232964, 232314)
// so removing it until we get it straightened out.
//
- (void)clickHoldCallback:(id)theEvent;
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK;

  if( theEvent == [NSApp currentEvent] ) {
    // we're still in the middle of the same mousedown event here, activate
    // click-hold context menu by triggering the right mouseDown action.
    NSEvent* clickHoldEvent = [NSEvent mouseEventWithType:NSRightMouseDown
                                                  location:[theEvent locationInWindow]
                                             modifierFlags:[theEvent modifierFlags]
                                                 timestamp:[theEvent timestamp]
                                              windowNumber:[theEvent windowNumber]
                                                   context:[theEvent context]
                                               eventNumber:[theEvent eventNumber]
                                                clickCount:[theEvent clickCount]
                                                  pressure:[theEvent pressure]];
    [self rightMouseDown:clickHoldEvent];
  }

  NS_OBJC_END_TRY_ABORT_BLOCK;
}
#endif

// If we've just created a non-native context menu, we need to mark it as
// such and let the OS (and other programs) know when it opens and closes
// (this is how the OS knows to close other programs' context menus when
// ours open).  We send the initial notification here, but others are sent
// in nsCocoaWindow::Show().
- (void)maybeInitContextMenuTracking
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK;

#ifdef MOZ_USE_NATIVE_POPUP_WINDOWS
  return;
#endif /* MOZ_USE_NATIVE_POPUP_WINDOWS */

  nsIRollupListener* rollupListener = nsBaseWidget::GetActiveRollupListener();
  NS_ENSURE_TRUE_VOID(rollupListener);
  nsCOMPtr<nsIWidget> widget = rollupListener->GetRollupWidget();
  NS_ENSURE_TRUE_VOID(widget);

  NSWindow *popupWindow = (NSWindow*)widget->GetNativeData(NS_NATIVE_WINDOW);
  if (!popupWindow || ![popupWindow isKindOfClass:[PopupWindow class]])
    return;

  [[NSDistributedNotificationCenter defaultCenter]
    postNotificationName:@"com.apple.HIToolbox.beginMenuTrackingNotification"
                  object:@"org.mozilla.goanna.PopupWindow"];
  [(PopupWindow*)popupWindow setIsContextMenu:YES];

  NS_OBJC_END_TRY_ABORT_BLOCK;
}

// Returns true if the event should no longer be processed, false otherwise.
// This does not return whether or not anything was rolled up.
- (BOOL)maybeRollup:(NSEvent*)theEvent
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_RETURN;

  BOOL consumeEvent = NO;

  nsIRollupListener* rollupListener = nsBaseWidget::GetActiveRollupListener();
  NS_ENSURE_TRUE(rollupListener, false);
  nsCOMPtr<nsIWidget> rollupWidget = rollupListener->GetRollupWidget();
  if (rollupWidget) {
    NSWindow* currentPopup = static_cast<NSWindow*>(rollupWidget->GetNativeData(NS_NATIVE_WINDOW));
    if (!nsCocoaUtils::IsEventOverWindow(theEvent, currentPopup)) {
      // event is not over the rollup window, default is to roll up
      bool shouldRollup = true;

      // check to see if scroll events should roll up the popup
      if ([theEvent type] == NSScrollWheel) {
        shouldRollup = rollupListener->ShouldRollupOnMouseWheelEvent();
        // consume scroll events that aren't over the popup
        // unless the popup is an arrow panel
        consumeEvent = rollupListener->ShouldConsumeOnMouseWheelEvent();
      }

      // if we're dealing with menus, we probably have submenus and
      // we don't want to rollup if the click is in a parent menu of
      // the current submenu
      uint32_t popupsToRollup = UINT32_MAX;
      nsAutoTArray<nsIWidget*, 5> widgetChain;
      uint32_t sameTypeCount = rollupListener->GetSubmenuWidgetChain(&widgetChain);
      for (uint32_t i = 0; i < widgetChain.Length(); i++) {
        nsIWidget* widget = widgetChain[i];
        NSWindow* currWindow = (NSWindow*)widget->GetNativeData(NS_NATIVE_WINDOW);
        if (nsCocoaUtils::IsEventOverWindow(theEvent, currWindow)) {
          // don't roll up if the mouse event occurred within a menu of the
          // same type. If the mouse event occurred in a menu higher than
          // that, roll up, but pass the number of popups to Rollup so
          // that only those of the same type close up.
          if (i < sameTypeCount) {
            shouldRollup = false;
          }
          else {
            popupsToRollup = sameTypeCount;
          }
          break;
        }
      }

      if (shouldRollup) {
        if ([theEvent type] == NSLeftMouseDown) {
          NSPoint point = [NSEvent mouseLocation];
          FlipCocoaScreenCoordinate(point);
          nsIntPoint pos(point.x, point.y);
          consumeEvent = (BOOL)rollupListener->Rollup(popupsToRollup, true, &pos, nullptr);
        }
        else {
          consumeEvent = (BOOL)rollupListener->Rollup(popupsToRollup, true, nullptr, nullptr);
        }
      }
    }
  }

  return consumeEvent;

  NS_OBJC_END_TRY_ABORT_BLOCK_RETURN(NO);
}

/*
 * In OS X Mountain Lion and above, smart zoom gestures are implemented in
 * smartMagnifyWithEvent. In OS X Lion, they are implemented in
 * magnifyWithEvent. See inline comments for more info.
 *
 * The prototypes swipeWithEvent, beginGestureWithEvent, magnifyWithEvent,
 * smartMagnifyWithEvent, rotateWithEvent, and endGestureWithEvent were
 * obtained from the following links:
 * https://developer.apple.com/library/mac/#documentation/Cocoa/Reference/ApplicationKit/Classes/NSResponder_Class/Reference/Reference.html
 * https://developer.apple.com/library/mac/#releasenotes/Cocoa/AppKit.html
 */

- (void)swipeWithEvent:(NSEvent *)anEvent
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK;

  if (!anEvent || !mGoannaChild)
    return;

  nsAutoRetainCocoaObject kungFuDeathGrip(self);

  float deltaX = [anEvent deltaX];  // left=1.0, right=-1.0
  float deltaY = [anEvent deltaY];  // up=1.0, down=-1.0

  // Setup the "swipe" event.
  WidgetSimpleGestureEvent goannaEvent(true, NS_SIMPLE_GESTURE_SWIPE,
                                      mGoannaChild);
  [self convertCocoaMouseEvent:anEvent toGoannaEvent:&goannaEvent];

  // Record the left/right direction.
  if (deltaX > 0.0)
    goannaEvent.direction |= nsIDOMSimpleGestureEvent::DIRECTION_LEFT;
  else if (deltaX < 0.0)
    goannaEvent.direction |= nsIDOMSimpleGestureEvent::DIRECTION_RIGHT;

  // Record the up/down direction.
  if (deltaY > 0.0)
    goannaEvent.direction |= nsIDOMSimpleGestureEvent::DIRECTION_UP;
  else if (deltaY < 0.0)
    goannaEvent.direction |= nsIDOMSimpleGestureEvent::DIRECTION_DOWN;

  // Send the event.
  mGoannaChild->DispatchWindowEvent(goannaEvent);

  NS_OBJC_END_TRY_ABORT_BLOCK;
}

- (void)beginGestureWithEvent:(NSEvent *)anEvent
{
  if (!anEvent)
    return;

  mGestureState = eGestureState_StartGesture;
  mCumulativeMagnification = 0;
  mCumulativeRotation = 0.0;
}

- (void)magnifyWithEvent:(NSEvent *)anEvent
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK;

  if (!anEvent || !mGoannaChild)
    return;

  /*
   * In OS X 10.7.* (Lion), smart zoom events come through magnifyWithEvent,
   * instead of smartMagnifyWithEvent. See bug 863841.
   */
  if ([ChildView isLionSmartMagnifyEvent: anEvent]) {
    [self smartMagnifyWithEvent: anEvent];
    return;
  }

  nsAutoRetainCocoaObject kungFuDeathGrip(self);

  float deltaZ = [anEvent deltaZ];

  uint32_t msg;
  switch (mGestureState) {
  case eGestureState_StartGesture:
    msg = NS_SIMPLE_GESTURE_MAGNIFY_START;
    mGestureState = eGestureState_MagnifyGesture;
    break;

  case eGestureState_MagnifyGesture:
    msg = NS_SIMPLE_GESTURE_MAGNIFY_UPDATE;
    break;

  case eGestureState_None:
  case eGestureState_RotateGesture:
  default:
    return;
  }

  // Setup the event.
  WidgetSimpleGestureEvent goannaEvent(true, msg, mGoannaChild);
  goannaEvent.delta = deltaZ;
  [self convertCocoaMouseEvent:anEvent toGoannaEvent:&goannaEvent];

  // Send the event.
  mGoannaChild->DispatchWindowEvent(goannaEvent);

  // Keep track of the cumulative magnification for the final "magnify" event.
  mCumulativeMagnification += deltaZ;

  NS_OBJC_END_TRY_ABORT_BLOCK;
}

- (void)smartMagnifyWithEvent:(NSEvent *)anEvent
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK;

  if (!anEvent || !mGoannaChild) {
    return;
  }

  nsAutoRetainCocoaObject kungFuDeathGrip(self);

  // Setup the "double tap" event.
  WidgetSimpleGestureEvent goannaEvent(true, NS_SIMPLE_GESTURE_TAP,
                                      mGoannaChild);
  [self convertCocoaMouseEvent:anEvent toGoannaEvent:&goannaEvent];
  goannaEvent.clickCount = 1;

  // Send the event.
  mGoannaChild->DispatchWindowEvent(goannaEvent);

  // Clear the gesture state
  mGestureState = eGestureState_None;

  NS_OBJC_END_TRY_ABORT_BLOCK;
}

- (void)rotateWithEvent:(NSEvent *)anEvent
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK;

  if (!anEvent || !mGoannaChild)
    return;

  nsAutoRetainCocoaObject kungFuDeathGrip(self);

  float rotation = [anEvent rotation];

  uint32_t msg;
  switch (mGestureState) {
  case eGestureState_StartGesture:
    msg = NS_SIMPLE_GESTURE_ROTATE_START;
    mGestureState = eGestureState_RotateGesture;
    break;

  case eGestureState_RotateGesture:
    msg = NS_SIMPLE_GESTURE_ROTATE_UPDATE;
    break;

  case eGestureState_None:
  case eGestureState_MagnifyGesture:
  default:
    return;
  }

  // Setup the event.
  WidgetSimpleGestureEvent goannaEvent(true, msg, mGoannaChild);
  [self convertCocoaMouseEvent:anEvent toGoannaEvent:&goannaEvent];
  goannaEvent.delta = -rotation;
  if (rotation > 0.0) {
    goannaEvent.direction = nsIDOMSimpleGestureEvent::ROTATION_COUNTERCLOCKWISE;
  } else {
    goannaEvent.direction = nsIDOMSimpleGestureEvent::ROTATION_CLOCKWISE;
  }

  // Send the event.
  mGoannaChild->DispatchWindowEvent(goannaEvent);

  // Keep track of the cumulative rotation for the final "rotate" event.
  mCumulativeRotation += rotation;

  NS_OBJC_END_TRY_ABORT_BLOCK;
}

- (void)endGestureWithEvent:(NSEvent *)anEvent
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK;

  if (!anEvent || !mGoannaChild) {
    // Clear the gestures state if we cannot send an event.
    mGestureState = eGestureState_None;
    mCumulativeMagnification = 0.0;
    mCumulativeRotation = 0.0;
    return;
  }

  nsAutoRetainCocoaObject kungFuDeathGrip(self);

  switch (mGestureState) {
  case eGestureState_MagnifyGesture:
    {
      // Setup the "magnify" event.
      WidgetSimpleGestureEvent goannaEvent(true, NS_SIMPLE_GESTURE_MAGNIFY,
                                          mGoannaChild);
      goannaEvent.delta = mCumulativeMagnification;
      [self convertCocoaMouseEvent:anEvent toGoannaEvent:&goannaEvent];

      // Send the event.
      mGoannaChild->DispatchWindowEvent(goannaEvent);
    }
    break;

  case eGestureState_RotateGesture:
    {
      // Setup the "rotate" event.
      WidgetSimpleGestureEvent goannaEvent(true, NS_SIMPLE_GESTURE_ROTATE,
                                          mGoannaChild);
      [self convertCocoaMouseEvent:anEvent toGoannaEvent:&goannaEvent];
      goannaEvent.delta = -mCumulativeRotation;
      if (mCumulativeRotation > 0.0) {
        goannaEvent.direction = nsIDOMSimpleGestureEvent::ROTATION_COUNTERCLOCKWISE;
      } else {
        goannaEvent.direction = nsIDOMSimpleGestureEvent::ROTATION_CLOCKWISE;
      }

      // Send the event.
      mGoannaChild->DispatchWindowEvent(goannaEvent);
    }
    break;

  case eGestureState_None:
  case eGestureState_StartGesture:
  default:
    break;
  }

  // Clear the gestures state.
  mGestureState = eGestureState_None;
  mCumulativeMagnification = 0.0;
  mCumulativeRotation = 0.0;

  NS_OBJC_END_TRY_ABORT_BLOCK;
}

+ (BOOL)isLionSmartMagnifyEvent:(NSEvent*)anEvent
{
  /*
   * On Lion, smart zoom events have type NSEventTypeGesture, subtype 0x16,
   * whereas pinch zoom events have type NSEventTypeMagnify. So, use that to
   * discriminate between the two. Smart zoom gestures do not call
   * beginGestureWithEvent or endGestureWithEvent, so mGestureState is not
   * changed. Documentation couldn't be found for the meaning of the subtype
   * 0x16, but it will probably never change. See bug 863841.
   */
  return nsCocoaFeatures::OnLionOrLater() &&
         !nsCocoaFeatures::OnMountainLionOrLater() &&
         [anEvent type] == NSEventTypeGesture &&
         [anEvent subtype] == 0x16;
}

#ifdef __LP64__
- (bool)sendSwipeEvent:(NSEvent*)aEvent
                withKind:(uint32_t)aMsg
       allowedDirections:(uint32_t*)aAllowedDirections
               direction:(uint32_t)aDirection
                   delta:(double)aDelta
{
  if (!mGoannaChild)
    return false;

  WidgetSimpleGestureEvent goannaEvent(true, aMsg, mGoannaChild);
  goannaEvent.direction = aDirection;
  goannaEvent.delta = aDelta;
  goannaEvent.allowedDirections = *aAllowedDirections;
  [self convertCocoaMouseEvent:aEvent toGoannaEvent:&goannaEvent];
  bool eventCancelled = mGoannaChild->DispatchWindowEvent(goannaEvent);
  *aAllowedDirections = goannaEvent.allowedDirections;
  return eventCancelled; // event cancelled == swipe should start
}

- (void)sendSwipeEndEvent:(NSEvent *)anEvent
        allowedDirections:(uint32_t)aAllowedDirections
{
    // Tear down animation overlay by sending a swipe end event.
    uint32_t allowedDirectionsCopy = aAllowedDirections;
    [self sendSwipeEvent:anEvent
                withKind:NS_SIMPLE_GESTURE_SWIPE_END
       allowedDirections:&allowedDirectionsCopy
               direction:0
                   delta:0.0];
}

// Support fluid swipe tracking on OS X 10.7 and higher. We must be careful
// to only invoke this support on a two-finger gesture that really
// is a swipe (and not a scroll) -- in other words, the app is responsible
// for deciding which is which. But once the decision is made, the OS tracks
// the swipe until it has finished, and decides whether or not it succeeded.
// A horizontal swipe has the same functionality as the Back and Forward
// buttons.
// This method is partly based on Apple sample code available at
// developer.apple.com/library/mac/#releasenotes/Cocoa/AppKitOlderNotes.html
// (under Fluid Swipe Tracking API).
- (void)maybeTrackScrollEventAsSwipe:(NSEvent *)anEvent
                     scrollOverflowX:(double)anOverflowX
                     scrollOverflowY:(double)anOverflowY
              viewPortIsOverscrolled:(BOOL)aViewPortIsOverscrolled
{
  if (!nsCocoaFeatures::OnLionOrLater()) {
    return;
  }

  // This method checks whether the AppleEnableSwipeNavigateWithScrolls global
  // preference is set.  If it isn't, fluid swipe tracking is disabled, and a
  // horizontal two-finger gesture is always a scroll (even in Safari).  This
  // preference can't (currently) be set from the Preferences UI -- only using
  // 'defaults write'.
  if (![NSEvent isSwipeTrackingFromScrollEventsEnabled]) {
    return;
  }

  // We should only track scroll events as swipe if the viewport is being
  // overscrolled.
  if (!aViewPortIsOverscrolled) {
    return;
  }

  NSEventPhase eventPhase = nsCocoaUtils::EventPhase(anEvent);
  // Verify that this is a scroll wheel event with proper phase to be tracked
  // by the OS.
  if ([anEvent type] != NSScrollWheel || eventPhase == NSEventPhaseNone) {
    return;
  }

  // Only initiate tracking if the user has tried to scroll past the edge of
  // the current page (as indicated by 'anOverflowX' or 'anOverflowY' being
  // non-zero). Goanna only sets WidgetMouseScrollEvent.scrollOverflow when it's
  // processing NS_MOUSE_PIXEL_SCROLL events (not NS_MOUSE_SCROLL events).
  if (anOverflowX == 0.0 && anOverflowY == 0.0) {
    return;
  }

  CGFloat deltaX, deltaY;
  if ([anEvent hasPreciseScrollingDeltas]) {
    deltaX = [anEvent scrollingDeltaX];
    deltaY = [anEvent scrollingDeltaY];
  } else {
    return;
  }

  uint32_t vDirs = (uint32_t)nsIDOMSimpleGestureEvent::DIRECTION_DOWN |
                   (uint32_t)nsIDOMSimpleGestureEvent::DIRECTION_UP;
  uint32_t direction = 0;

  // Only initiate horizontal tracking for events whose horizontal element is
  // at least eight times larger than its vertical element. This minimizes
  // performance problems with vertical scrolls (by minimizing the possibility
  // that they'll be misinterpreted as horizontal swipes), while still
  // tolerating a small vertical element to a true horizontal swipe.  The number
  // '8' was arrived at by trial and error.
  if (anOverflowX != 0.0 && deltaX != 0.0 &&
      std::abs(deltaX) > std::abs(deltaY) * 8) {
    // Only initiate horizontal tracking for gestures that have just begun --
    // otherwise a scroll to one side of the page can have a swipe tacked on
    // to it.
    if (eventPhase != NSEventPhaseBegan) {
      return;
    }

    if (deltaX < 0.0) {
      direction = (uint32_t)nsIDOMSimpleGestureEvent::DIRECTION_RIGHT;
    } else {
      direction = (uint32_t)nsIDOMSimpleGestureEvent::DIRECTION_LEFT;
    }
  }
  // Only initiate vertical tracking for events whose vertical element is
  // at least two times larger than its horizontal element. This minimizes
  // performance problems. The number '2' was arrived at by trial and error.
  else if (anOverflowY != 0.0 && deltaY != 0.0 &&
           std::abs(deltaY) > std::abs(deltaX) * 2) {
    if (deltaY < 0.0) {
      direction = (uint32_t)nsIDOMSimpleGestureEvent::DIRECTION_DOWN;
    } else {
      direction = (uint32_t)nsIDOMSimpleGestureEvent::DIRECTION_UP;
    }

    if ((mCurrentSwipeDir & vDirs) && (mCurrentSwipeDir != direction)) {
      // If a swipe is currently being tracked kill it -- it's been interrupted
      // by another gesture event.
      if (mCancelSwipeAnimation && *mCancelSwipeAnimation == NO) {
        *mCancelSwipeAnimation = YES;
        mCancelSwipeAnimation = nil;
        [self sendSwipeEndEvent:anEvent allowedDirections:0];
      }
      return;
    }
  } else {
    return;
  }

  // Track the direction we're going in.
  mCurrentSwipeDir = direction;

  uint32_t allowedDirections = 0;
  // We're ready to start the animation. Tell Goanna about it, and at the same
  // time ask it if it really wants to start an animation for this event.
  // This event also reports back the directions that we can swipe in.
  bool shouldStartSwipe = [self sendSwipeEvent:anEvent
                                      withKind:NS_SIMPLE_GESTURE_SWIPE_START
                             allowedDirections:&allowedDirections
                                     direction:direction
                                         delta:0.0];

  if (!shouldStartSwipe) {
    return;
  }

  // If a swipe is currently being tracked kill it -- it's been interrupted
  // by another gesture event.
  if (mCancelSwipeAnimation && *mCancelSwipeAnimation == NO) {
    *mCancelSwipeAnimation = YES;
    mCancelSwipeAnimation = nil;
  }

  CGFloat min = 0.0;
  CGFloat max = 0.0;
  if (!(direction & vDirs)) {
    min = (allowedDirections & nsIDOMSimpleGestureEvent::DIRECTION_RIGHT) ?
          -1.0 : 0.0;
    max = (allowedDirections & nsIDOMSimpleGestureEvent::DIRECTION_LEFT) ?
          1.0 : 0.0;
  }

  __block BOOL animationCanceled = NO;
  __block BOOL goannaSwipeEventSent = NO;
  // At this point, anEvent is the first scroll wheel event in a two-finger
  // horizontal gesture that we've decided to treat as a swipe.  When we call
  // [NSEvent trackSwipeEventWithOptions:...], the OS interprets all
  // subsequent scroll wheel events that are part of this gesture as a swipe,
  // and stops sending them to us.  The OS calls the trackingHandler "block"
  // multiple times, asynchronously (sometimes after [NSEvent
  // maybeTrackScrollEventAsSwipe:...] has returned).  The OS determines when
  // the gesture has finished, and whether or not it was "successful" -- this
  // information is passed to trackingHandler.  We must be careful to only
  // call [NSEvent maybeTrackScrollEventAsSwipe:...] on a "real" swipe --
  // otherwise two-finger scrolling performance will suffer significantly.
  // Note that we use anEvent inside the block. This extends the lifetime of
  // the anEvent object because it's retained by the block, see bug 682445.
  // The block will release it when the block goes away at the end of the
  // animation, or when the animation is canceled.
  [anEvent trackSwipeEventWithOptions:NSEventSwipeTrackingLockDirection |
                                      NSEventSwipeTrackingClampGestureAmount
             dampenAmountThresholdMin:min
                                  max:max
                         usingHandler:^(CGFloat gestureAmount,
                                        NSEventPhase phase,
                                        BOOL isComplete,
                                        BOOL *stop) {
    uint32_t allowedDirectionsCopy = allowedDirections;
    // Since this tracking handler can be called asynchronously, mGoannaChild
    // might have become NULL here (our child widget might have been
    // destroyed).
    // Checking for gestureAmount == 0.0 also works around bug 770626, which
    // happens when DispatchWindowEvent() triggers a modal dialog, which spins
    // the event loop and confuses the OS. This results in several re-entrant
    // calls to this handler.
    if (animationCanceled || !mGoannaChild || gestureAmount == 0.0) {
      *stop = YES;
      animationCanceled = YES;
      if (gestureAmount == 0.0 ||
          ((direction & vDirs) && (direction != mCurrentSwipeDir))) {
        if (mCancelSwipeAnimation)
          *mCancelSwipeAnimation = YES;
        mCancelSwipeAnimation = nil;
        [self sendSwipeEndEvent:anEvent
              allowedDirections:allowedDirectionsCopy];
      }
      mCurrentSwipeDir = 0;
      return;
    }

    // Update animation overlay to match gestureAmount.
    [self sendSwipeEvent:anEvent
                withKind:NS_SIMPLE_GESTURE_SWIPE_UPDATE
       allowedDirections:&allowedDirectionsCopy
               direction:0.0
                   delta:gestureAmount];

    if (phase == NSEventPhaseEnded && !goannaSwipeEventSent) {
      // The result of the swipe is now known, so the main event can be sent.
      // The animation might continue even after this event was sent, so
      // don't tear down the animation overlay yet.

      uint32_t directionCopy = direction;

      // gestureAmount is documented to be '-1', '0' or '1' when isComplete
      // is TRUE, but the docs don't say anything about its value at other
      // times.  However, tests show that, when phase == NSEventPhaseEnded,
      // gestureAmount is negative when it will be '-1' at isComplete, and
      // positive when it will be '1'.  And phase is never equal to
      // NSEventPhaseEnded when gestureAmount will be '0' at isComplete.
      goannaSwipeEventSent = YES;
      [self sendSwipeEvent:anEvent
                  withKind:NS_SIMPLE_GESTURE_SWIPE
         allowedDirections:&allowedDirectionsCopy
                 direction:directionCopy
                     delta:0.0];
    }

    if (isComplete) {
      [self sendSwipeEndEvent:anEvent allowedDirections:allowedDirectionsCopy];
      mCurrentSwipeDir = 0;
      mCancelSwipeAnimation = nil;
    }
  }];

  mCancelSwipeAnimation = &animationCanceled;
}
#endif // #ifdef __LP64__

- (void)setUsingOMTCompositor:(BOOL)aUseOMTC
{
  mUsingOMTCompositor = aUseOMTC;
}

// Returning NO from this method only disallows ordering on mousedown - in order
// to prevent it for mouseup too, we need to call [NSApp preventWindowOrdering]
// when handling the mousedown event.
- (BOOL)shouldDelayWindowOrderingForEvent:(NSEvent*)aEvent
{
  // Always using system-provided window ordering for normal windows.
  if (![[self window] isKindOfClass:[PopupWindow class]])
    return NO;

  // Don't reorder when we don't have a parent window, like when we're a
  // context menu or a tooltip.
  return ![[self window] parentWindow];
}

- (void)mouseDown:(NSEvent*)theEvent
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK;

  if ([self shouldDelayWindowOrderingForEvent:theEvent]) {
    [NSApp preventWindowOrdering];
  }

  // If we've already seen this event due to direct dispatch from menuForEvent:
  // just bail; if not, remember it.
  if (mLastMouseDownEvent == theEvent) {
    [mLastMouseDownEvent release];
    mLastMouseDownEvent = nil;
    return;
  }
  else {
    [mLastMouseDownEvent release];
    mLastMouseDownEvent = [theEvent retain];
  }

  [gLastDragMouseDownEvent release];
  gLastDragMouseDownEvent = [theEvent retain];

  // We need isClickThrough because at this point the window we're in might
  // already have become main, so the check for isMainWindow in
  // WindowAcceptsEvent isn't enough. It also has to check isClickThrough.
  BOOL isClickThrough = (theEvent == mClickThroughMouseDownEvent);
  [mClickThroughMouseDownEvent release];
  mClickThroughMouseDownEvent = nil;

  nsAutoRetainCocoaObject kungFuDeathGrip(self);

  if ([self maybeRollup:theEvent] ||
      !ChildViewMouseTracker::WindowAcceptsEvent([self window], theEvent, self, isClickThrough)) {
    // Remember blocking because that means we want to block mouseup as well.
    mBlockedLastMouseDown = YES;
    return;
  }

#if USE_CLICK_HOLD_CONTEXTMENU
  // fire off timer to check for click-hold after two seconds. retains |theEvent|
  [self performSelector:@selector(clickHoldCallback:) withObject:theEvent afterDelay:2.0];
#endif

  // in order to send goanna events we'll need a goanna widget
  if (!mGoannaChild)
    return;

  NSUInteger modifierFlags = [theEvent modifierFlags];

  WidgetMouseEvent goannaEvent(true, NS_MOUSE_BUTTON_DOWN, mGoannaChild,
                              WidgetMouseEvent::eReal);
  [self convertCocoaMouseEvent:theEvent toGoannaEvent:&goannaEvent];

  NSInteger clickCount = [theEvent clickCount];
  if (mBlockedLastMouseDown && clickCount > 1) {
    // Don't send a double click if the first click of the double click was
    // blocked.
    clickCount--;
  }
  goannaEvent.clickCount = clickCount;

  if (modifierFlags & NSControlKeyMask)
    goannaEvent.button = WidgetMouseEvent::eRightButton;
  else
    goannaEvent.button = WidgetMouseEvent::eLeftButton;

  mGoannaChild->DispatchWindowEvent(goannaEvent);
  mBlockedLastMouseDown = NO;

  // XXX maybe call markedTextSelectionChanged:client: here?

  NS_OBJC_END_TRY_ABORT_BLOCK;
}

- (void)mouseUp:(NSEvent *)theEvent
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK;

  if (!mGoannaChild || mBlockedLastMouseDown)
    return;

  nsAutoRetainCocoaObject kungFuDeathGrip(self);

  WidgetMouseEvent goannaEvent(true, NS_MOUSE_BUTTON_UP, mGoannaChild,
                              WidgetMouseEvent::eReal);
  [self convertCocoaMouseEvent:theEvent toGoannaEvent:&goannaEvent];
  if ([theEvent modifierFlags] & NSControlKeyMask)
    goannaEvent.button = WidgetMouseEvent::eRightButton;
  else
    goannaEvent.button = WidgetMouseEvent::eLeftButton;

  // This might destroy our widget (and null out mGoannaChild).
  bool defaultPrevented = mGoannaChild->DispatchWindowEvent(goannaEvent);

  // Check to see if we are double-clicking in the titlebar.
  CGFloat locationInTitlebar = [[self window] frame].size.height - [theEvent locationInWindow].y;
  LayoutDeviceIntPoint pos = goannaEvent.refPoint;
  if (!defaultPrevented && [theEvent clickCount] == 2 &&
      mGoannaChild->GetDraggableRegion().Contains(pos.x, pos.y) &&
      [[self window] isKindOfClass:[ToolbarWindow class]] &&
      (locationInTitlebar < [(ToolbarWindow*)[self window] titlebarHeight] ||
       locationInTitlebar < [(ToolbarWindow*)[self window] unifiedToolbarHeight])) {
    if ([self shouldZoomOnDoubleClick]) {
      [[self window] performZoom:nil];
    } else if ([self shouldMinimizeOnTitlebarDoubleClick]) {
      NSButton *minimizeButton = [[self window] standardWindowButton:NSWindowMiniaturizeButton];
      [minimizeButton performClick:self];
    }
  }

  NS_OBJC_END_TRY_ABORT_BLOCK;
}

- (void)sendMouseEnterOrExitEvent:(NSEvent*)aEvent
                            enter:(BOOL)aEnter
                             type:(WidgetMouseEvent::exitType)aType
{
  if (!mGoannaChild)
    return;

  NSPoint windowEventLocation = nsCocoaUtils::EventLocationForWindow(aEvent, [self window]);
  NSPoint localEventLocation = [self convertPoint:windowEventLocation fromView:nil];

  uint32_t msg = aEnter ? NS_MOUSE_ENTER : NS_MOUSE_EXIT;
  WidgetMouseEvent event(true, msg, mGoannaChild, WidgetMouseEvent::eReal);
  event.refPoint = LayoutDeviceIntPoint::FromUntyped(
    mGoannaChild->CocoaPointsToDevPixels(localEventLocation));

  event.exit = aType;

  nsEventStatus status; // ignored
  mGoannaChild->DispatchEvent(&event, status);
}

- (void)updateWindowDraggableState
{
  // Trigger update to the window server.
  [[self window] setMovableByWindowBackground:NO];
  [[self window] setMovableByWindowBackground:YES];
}

// aRect is in view coordinates relative to this NSView.
- (CGRect)convertToFlippedWindowCoordinates:(NSRect)aRect
{
  // First, convert the rect to regular window coordinates...
  NSRect inWindowCoords = [self convertRect:aRect toView:nil];
  // ... and then flip it again because window coordinates have their origin
  // in the bottom left corner, and we need it to be in the top left corner.
  inWindowCoords.origin.y = [[self window] frame].size.height - NSMaxY(inWindowCoords);
  return NSRectToCGRect(inWindowCoords);
}

static CGSRegionObj
NewCGSRegionFromRegion(const nsIntRegion& aRegion,
                       CGRect (^aRectConverter)(const nsIntRect&))
{
  nsTArray<CGRect> rects;
  nsIntRegionRectIterator iter(aRegion);
  for (;;) {
    const nsIntRect* r = iter.Next();
    if (!r)
      break;
    rects.AppendElement(aRectConverter(*r));
  }

  CGSRegionObj region;
  CGSNewRegionWithRectList(rects.Elements(), rects.Length(), &region);
  return region;
}

// This function is called with forMove:YES to calculate the draggable region
// of the window which will be submitted to the window server. Window dragging
// is handled on the window server without calling back into our process, so it
// also works while our app is unresponsive.
- (CGSRegionObj)_regionForOpaqueDescendants:(NSRect)aRect forMove:(BOOL)aForMove
{
  if (!aForMove || !mGoannaChild) {
    return [super _regionForOpaqueDescendants:aRect forMove:aForMove];
  }

  nsIntRect boundingRect = mGoannaChild->CocoaPointsToDevPixels(aRect);

  nsIntRegion opaqueRegion;
  opaqueRegion.Sub(boundingRect, mGoannaChild->GetDraggableRegion());

  return NewCGSRegionFromRegion(opaqueRegion, ^(const nsIntRect& r) {
    return [self convertToFlippedWindowCoordinates:mGoannaChild->DevPixelsToCocoaPoints(r)];
  });
}

// Starting with 10.10, in addition to the traditional
// -[NSView _regionForOpaqueDescendants:forMove:] method, there's a new form with
// an additional forUnderTitlebar argument, which is sometimes called instead of
// the old form. We need to override the new variant as well.
- (CGSRegionObj)_regionForOpaqueDescendants:(NSRect)aRect
                                    forMove:(BOOL)aForMove
                           forUnderTitlebar:(BOOL)aForUnderTitlebar
{
  if (!aForMove || !mGoannaChild) {
    return [super _regionForOpaqueDescendants:aRect
                                      forMove:aForMove
                             forUnderTitlebar:aForUnderTitlebar];
  }

  return [self _regionForOpaqueDescendants:aRect forMove:aForMove];
}

- (void)handleMouseMoved:(NSEvent*)theEvent
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK;

  if (!mGoannaChild)
    return;

  WidgetMouseEvent goannaEvent(true, NS_MOUSE_MOVE, mGoannaChild,
                              WidgetMouseEvent::eReal);
  [self convertCocoaMouseEvent:theEvent toGoannaEvent:&goannaEvent];

  mGoannaChild->DispatchWindowEvent(goannaEvent);

  NS_OBJC_END_TRY_ABORT_BLOCK;
}

- (void)mouseDragged:(NSEvent*)theEvent
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK;

  if (!mGoannaChild)
    return;

  gLastDragView = self;

  WidgetMouseEvent goannaEvent(true, NS_MOUSE_MOVE, mGoannaChild,
                              WidgetMouseEvent::eReal);
  [self convertCocoaMouseEvent:theEvent toGoannaEvent:&goannaEvent];

  mGoannaChild->DispatchWindowEvent(goannaEvent);

  // Note, sending the above event might have destroyed our widget since we didn't retain.
  // Fine so long as we don't access any local variables from here on.
  gLastDragView = nil;

  // XXX maybe call markedTextSelectionChanged:client: here?

  NS_OBJC_END_TRY_ABORT_BLOCK;
}

- (void)rightMouseDown:(NSEvent *)theEvent
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK;

  nsAutoRetainCocoaObject kungFuDeathGrip(self);

  [self maybeRollup:theEvent];
  if (!mGoannaChild)
    return;

  // The right mouse went down, fire off a right mouse down event to goanna
  WidgetMouseEvent goannaEvent(true, NS_MOUSE_BUTTON_DOWN, mGoannaChild,
                              WidgetMouseEvent::eReal);
  [self convertCocoaMouseEvent:theEvent toGoannaEvent:&goannaEvent];
  goannaEvent.button = WidgetMouseEvent::eRightButton;
  goannaEvent.clickCount = [theEvent clickCount];

  mGoannaChild->DispatchWindowEvent(goannaEvent);
  if (!mGoannaChild)
    return;

  // Let the superclass do the context menu stuff.
  [super rightMouseDown:theEvent];

  NS_OBJC_END_TRY_ABORT_BLOCK;
}

- (void)rightMouseUp:(NSEvent *)theEvent
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK;

  if (!mGoannaChild)
    return;

  WidgetMouseEvent goannaEvent(true, NS_MOUSE_BUTTON_UP, mGoannaChild,
                              WidgetMouseEvent::eReal);
  [self convertCocoaMouseEvent:theEvent toGoannaEvent:&goannaEvent];
  goannaEvent.button = WidgetMouseEvent::eRightButton;
  goannaEvent.clickCount = [theEvent clickCount];

  nsAutoRetainCocoaObject kungFuDeathGrip(self);
  mGoannaChild->DispatchWindowEvent(goannaEvent);

  NS_OBJC_END_TRY_ABORT_BLOCK;
}

- (void)rightMouseDragged:(NSEvent*)theEvent
{
  if (!mGoannaChild)
    return;

  WidgetMouseEvent goannaEvent(true, NS_MOUSE_MOVE, mGoannaChild,
                              WidgetMouseEvent::eReal);
  [self convertCocoaMouseEvent:theEvent toGoannaEvent:&goannaEvent];
  goannaEvent.button = WidgetMouseEvent::eRightButton;

  // send event into Goanna by going directly to the
  // the widget.
  mGoannaChild->DispatchWindowEvent(goannaEvent);
}

- (void)otherMouseDown:(NSEvent *)theEvent
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK;

  nsAutoRetainCocoaObject kungFuDeathGrip(self);

  if ([self maybeRollup:theEvent] ||
      !ChildViewMouseTracker::WindowAcceptsEvent([self window], theEvent, self))
    return;

  if (!mGoannaChild)
    return;

  WidgetMouseEvent goannaEvent(true, NS_MOUSE_BUTTON_DOWN, mGoannaChild,
                              WidgetMouseEvent::eReal);
  [self convertCocoaMouseEvent:theEvent toGoannaEvent:&goannaEvent];
  goannaEvent.button = WidgetMouseEvent::eMiddleButton;
  goannaEvent.clickCount = [theEvent clickCount];

  mGoannaChild->DispatchWindowEvent(goannaEvent);

  NS_OBJC_END_TRY_ABORT_BLOCK;
}

- (void)otherMouseUp:(NSEvent *)theEvent
{
  if (!mGoannaChild)
    return;

  WidgetMouseEvent goannaEvent(true, NS_MOUSE_BUTTON_UP, mGoannaChild,
                              WidgetMouseEvent::eReal);
  [self convertCocoaMouseEvent:theEvent toGoannaEvent:&goannaEvent];
  goannaEvent.button = WidgetMouseEvent::eMiddleButton;

  nsAutoRetainCocoaObject kungFuDeathGrip(self);
  mGoannaChild->DispatchWindowEvent(goannaEvent);
}

- (void)otherMouseDragged:(NSEvent*)theEvent
{
  if (!mGoannaChild)
    return;

  WidgetMouseEvent goannaEvent(true, NS_MOUSE_MOVE, mGoannaChild,
                              WidgetMouseEvent::eReal);
  [self convertCocoaMouseEvent:theEvent toGoannaEvent:&goannaEvent];
  goannaEvent.button = WidgetMouseEvent::eMiddleButton;

  // send event into Goanna by going directly to the
  // the widget.
  mGoannaChild->DispatchWindowEvent(goannaEvent);
}

static int32_t RoundUp(double aDouble)
{
  return aDouble < 0 ? static_cast<int32_t>(floor(aDouble)) :
                       static_cast<int32_t>(ceil(aDouble));
}

- (void)sendWheelStartOrStop:(uint32_t)msg forEvent:(NSEvent *)theEvent
{
  WidgetWheelEvent wheelEvent(true, msg, mGoannaChild);
  [self convertCocoaMouseWheelEvent:theEvent toGoannaEvent:&wheelEvent];
  mExpectingWheelStop = (msg == NS_WHEEL_START);
  mGoannaChild->DispatchWindowEvent(wheelEvent);
}

- (void)sendWheelCondition:(BOOL)condition first:(uint32_t)first second:(uint32_t)second forEvent:(NSEvent *)theEvent
{
  if (mExpectingWheelStop == condition) {
    [self sendWheelStartOrStop:first forEvent:theEvent];
  }
  [self sendWheelStartOrStop:second forEvent:theEvent];
}

- (void)scrollWheel:(NSEvent*)theEvent
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK;

  if ([self apzctm]) {
    // Disable main-thread scrolling completely when using APZC.
    return;
  }

  nsAutoRetainCocoaObject kungFuDeathGrip(self);

  ChildViewMouseTracker::MouseScrolled(theEvent);

  if ([self maybeRollup:theEvent]) {
    return;
  }

  if (!mGoannaChild) {
    return;
  }

  NSEventPhase phase = nsCocoaUtils::EventPhase(theEvent);
  // Fire NS_WHEEL_START/STOP events when 2 fingers touch/release the touchpad.
  if (phase & NSEventPhaseMayBegin) {
    [self sendWheelCondition:YES first:NS_WHEEL_STOP second:NS_WHEEL_START forEvent:theEvent];
    return;
  }

  if (phase & (NSEventPhaseEnded | NSEventPhaseCancelled)) {
    [self sendWheelCondition:NO first:NS_WHEEL_START second:NS_WHEEL_STOP forEvent:theEvent];
    return;
  }

  WidgetWheelEvent wheelEvent(true, NS_WHEEL_WHEEL, mGoannaChild);
  [self convertCocoaMouseWheelEvent:theEvent toGoannaEvent:&wheelEvent];

  wheelEvent.lineOrPageDeltaX = RoundUp(-[theEvent deltaX]);
  wheelEvent.lineOrPageDeltaY = RoundUp(-[theEvent deltaY]);

  // wheelEvent.deltaMode was set by convertCocoaMouseWheelEvent:toGoannaEvent:
  // and depends on whether the current scrolling device supports pixel deltas.
  if (wheelEvent.deltaMode == nsIDOMWheelEvent::DOM_DELTA_PIXEL) {
    double scale = mGoannaChild->BackingScaleFactor();
    CGFloat pixelDeltaX = 0, pixelDeltaY = 0;
    nsCocoaUtils::GetScrollingDeltas(theEvent, &pixelDeltaX, &pixelDeltaY);
    wheelEvent.deltaX = -pixelDeltaX * scale;
    wheelEvent.deltaY = -pixelDeltaY * scale;
  } else {
    wheelEvent.deltaX = -[theEvent deltaX];
    wheelEvent.deltaY = -[theEvent deltaY];
  }

  // TODO: We should not set deltaZ for now because we're not sure if we should
  //       revert the sign.
  // wheelEvent.deltaZ = [theEvent deltaZ];

  if (!wheelEvent.deltaX && !wheelEvent.deltaY && !wheelEvent.deltaZ) {
    // No sense in firing off a Goanna event.
    return;
  }

  mGoannaChild->DispatchWindowEvent(wheelEvent);
  if (!mGoannaChild) {
    return;
  }

#ifdef __LP64__
  // overflowDeltaX and overflowDeltaY tell us when the user has tried to
  // scroll past the edge of a page (in those cases it's non-zero).
  if ((wheelEvent.deltaMode == nsIDOMWheelEvent::DOM_DELTA_PIXEL) &&
      (wheelEvent.deltaX != 0.0 || wheelEvent.deltaY != 0.0)) {
    [self maybeTrackScrollEventAsSwipe:theEvent
                       scrollOverflowX:wheelEvent.overflowDeltaX
                       scrollOverflowY:wheelEvent.overflowDeltaY
                viewPortIsOverscrolled:wheelEvent.mViewPortIsOverscrolled];
  }
#endif // #ifdef __LP64__

  NS_OBJC_END_TRY_ABORT_BLOCK;
}

- (void)handleAsyncScrollEvent:(CGEventRef)cgEvent ofType:(CGEventType)type
{
  APZCTreeManager* apzctm = [self apzctm];
  if (!apzctm) {
    return;
  }

  CGPoint loc = CGEventGetLocation(cgEvent);
  loc.y = nsCocoaUtils::FlippedScreenY(loc.y);
  NSPoint locationInWindow = [[self window] convertScreenToBase:NSPointFromCGPoint(loc)];
  ScreenIntPoint location = ScreenPixel::FromUntyped([self convertWindowCoordinates:locationInWindow]);

  static NSTimeInterval sStartTime = [NSDate timeIntervalSinceReferenceDate];
  static TimeStamp sStartTimeStamp = TimeStamp::Now();

  if (type == kCGEventScrollWheel) {
    NSEvent* event = [NSEvent eventWithCGEvent:cgEvent];
    NSEventPhase phase = nsCocoaUtils::EventPhase(event);
    NSEventPhase momentumPhase = nsCocoaUtils::EventMomentumPhase(event);
    CGFloat pixelDeltaX = 0, pixelDeltaY = 0;
    nsCocoaUtils::GetScrollingDeltas(event, &pixelDeltaX, &pixelDeltaY);
    uint32_t eventTime = ([event timestamp] - sStartTime) * 1000;
    TimeStamp eventTimeStamp = sStartTimeStamp +
      TimeDuration::FromSeconds([event timestamp] - sStartTime);
    NSPoint locationInWindowMoved = NSMakePoint(
      locationInWindow.x + pixelDeltaX,
      locationInWindow.y - pixelDeltaY);
    ScreenIntPoint locationMoved = ScreenPixel::FromUntyped(
      [self convertWindowCoordinates:locationInWindowMoved]);
    ScreenPoint delta = ScreenPoint(locationMoved - location);
    ScrollableLayerGuid guid;

    // MayBegin and Cancelled are dispatched when the fingers start or stop
    // touching the touchpad before any scrolling has occurred. These events
    // can be used to control scrollbar visibility or interrupt scroll
    // animations. They are only dispatched on 10.8 or later, and only by
    // relatively modern devices.
    if (phase == NSEventPhaseMayBegin) {
      PanGestureInput panInput(PanGestureInput::PANGESTURE_MAYSTART, eventTime,
                               eventTimeStamp, location, ScreenPoint(0, 0), 0);
      apzctm->ReceiveInputEvent(panInput, &guid, nullptr);
      return;
    }
    if (phase == NSEventPhaseCancelled) {
      PanGestureInput panInput(PanGestureInput::PANGESTURE_CANCELLED, eventTime,
                               eventTimeStamp, location, ScreenPoint(0, 0), 0);
      apzctm->ReceiveInputEvent(panInput, &guid, nullptr);
      return;
    }

    // Legacy scroll events are dispatched by devices that do not have a
    // concept of a scroll gesture, for example by USB mice with
    // traditional mouse wheels.
    // For these kinds of scrolls, we want to surround every single scroll
    // event with a PANGESTURE_START and a PANGESTURE_END event. The APZC
    // needs to know that the real scroll gesture can end abruptly after any
    // one of these events.
    bool isLegacyScroll = (phase == NSEventPhaseNone &&
      momentumPhase == NSEventPhaseNone && delta != ScreenPoint(0, 0));

    if (phase == NSEventPhaseBegan || isLegacyScroll) {
      PanGestureInput panInput(PanGestureInput::PANGESTURE_START, eventTime,
                               eventTimeStamp, location, ScreenPoint(0, 0), 0);
      apzctm->ReceiveInputEvent(panInput, &guid, nullptr);
    }
    if (momentumPhase == NSEventPhaseNone && delta != ScreenPoint(0, 0)) {
      PanGestureInput panInput(PanGestureInput::PANGESTURE_PAN, eventTime,
                               eventTimeStamp, location, delta, 0);
      apzctm->ReceiveInputEvent(panInput, &guid, nullptr);
    }
    if (phase == NSEventPhaseEnded || isLegacyScroll) {
      PanGestureInput panInput(PanGestureInput::PANGESTURE_END, eventTime,
                               eventTimeStamp, location, ScreenPoint(0, 0), 0);
      apzctm->ReceiveInputEvent(panInput, &guid, nullptr);
    }

    // Any device that can dispatch momentum events supports all three momentum phases.
    if (momentumPhase == NSEventPhaseBegan) {
      PanGestureInput panInput(PanGestureInput::PANGESTURE_MOMENTUMSTART, eventTime,
                               eventTimeStamp, location, ScreenPoint(0, 0), 0);
      apzctm->ReceiveInputEvent(panInput, &guid, nullptr);
    }
    if (momentumPhase == NSEventPhaseChanged && delta != ScreenPoint(0, 0)) {
      PanGestureInput panInput(PanGestureInput::PANGESTURE_MOMENTUMPAN, eventTime,
                               eventTimeStamp, location, delta, 0);
      apzctm->ReceiveInputEvent(panInput, &guid, nullptr);
    }
    if (momentumPhase == NSEventPhaseEnded) {
      PanGestureInput panInput(PanGestureInput::PANGESTURE_MOMENTUMEND, eventTime,
                               eventTimeStamp, location, ScreenPoint(0, 0), 0);
      apzctm->ReceiveInputEvent(panInput, &guid, nullptr);
    }
  }
}

-(NSMenu*)menuForEvent:(NSEvent*)theEvent
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_NIL;

  if (!mGoannaChild)
    return nil;

  nsAutoRetainCocoaObject kungFuDeathGrip(self);

  [self maybeRollup:theEvent];
  if (!mGoannaChild)
    return nil;

  // Cocoa doesn't always dispatch a mouseDown: for a control-click event,
  // depends on what we return from menuForEvent:. Goanna always expects one
  // and expects the mouse down event before the context menu event, so
  // get that event sent first if this is a left mouse click.
  if ([theEvent type] == NSLeftMouseDown) {
    [self mouseDown:theEvent];
    if (!mGoannaChild)
      return nil;
  }

  WidgetMouseEvent goannaEvent(true, NS_CONTEXTMENU, mGoannaChild,
                              WidgetMouseEvent::eReal);
  [self convertCocoaMouseEvent:theEvent toGoannaEvent:&goannaEvent];
  goannaEvent.button = WidgetMouseEvent::eRightButton;
  mGoannaChild->DispatchWindowEvent(goannaEvent);
  if (!mGoannaChild)
    return nil;

  [self maybeInitContextMenuTracking];

  // Go up our view chain to fetch the correct menu to return.
  return [self contextMenu];

  NS_OBJC_END_TRY_ABORT_BLOCK_NIL;
}

- (NSMenu*)contextMenu
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_NIL;

  NSView* superView = [self superview];
  if ([superView respondsToSelector:@selector(contextMenu)])
    return [(NSView<mozView>*)superView contextMenu];

  return nil;

  NS_OBJC_END_TRY_ABORT_BLOCK_NIL;
}

- (void) convertCocoaMouseWheelEvent:(NSEvent*)aMouseEvent
                        toGoannaEvent:(WidgetWheelEvent*)outWheelEvent
{
  [self convertCocoaMouseEvent:aMouseEvent toGoannaEvent:outWheelEvent];

  bool usePreciseDeltas = nsCocoaUtils::HasPreciseScrollingDeltas(aMouseEvent) &&
    Preferences::GetBool("mousewheel.enable_pixel_scrolling", true);

  outWheelEvent->deltaMode = usePreciseDeltas ? nsIDOMWheelEvent::DOM_DELTA_PIXEL
                                              : nsIDOMWheelEvent::DOM_DELTA_LINE;
  outWheelEvent->isMomentum = nsCocoaUtils::IsMomentumScrollEvent(aMouseEvent);
}

- (void) convertCocoaMouseEvent:(NSEvent*)aMouseEvent
                   toGoannaEvent:(WidgetInputEvent*)outGoannaEvent
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK;

  NS_ASSERTION(outGoannaEvent, "convertCocoaMouseEvent:toGoannaEvent: requires non-null aoutGoannaEvent");
  if (!outGoannaEvent)
    return;

  nsCocoaUtils::InitInputEvent(*outGoannaEvent, aMouseEvent);

  // convert point to view coordinate system
  NSPoint locationInWindow = nsCocoaUtils::EventLocationForWindow(aMouseEvent, [self window]);

  outGoannaEvent->refPoint = LayoutDeviceIntPoint::FromUntyped(
    [self convertWindowCoordinates:locationInWindow]);

  WidgetMouseEventBase* mouseEvent = outGoannaEvent->AsMouseEventBase();
  mouseEvent->buttons = 0;
  NSUInteger mouseButtons = [NSEvent pressedMouseButtons];

  if (mouseButtons & 0x01) {
    mouseEvent->buttons |= WidgetMouseEvent::eLeftButtonFlag;
  }
  if (mouseButtons & 0x02) {
    mouseEvent->buttons |= WidgetMouseEvent::eRightButtonFlag;
  }
  if (mouseButtons & 0x04) {
    mouseEvent->buttons |= WidgetMouseEvent::eMiddleButtonFlag;
  }
  if (mouseButtons & 0x08) {
    mouseEvent->buttons |= WidgetMouseEvent::e4thButtonFlag;
  }
  if (mouseButtons & 0x10) {
    mouseEvent->buttons |= WidgetMouseEvent::e5thButtonFlag;
  }

  switch ([aMouseEvent type]) {
    case NSLeftMouseDown:
    case NSLeftMouseUp:
    case NSLeftMouseDragged:
    case NSRightMouseDown:
    case NSRightMouseUp:
    case NSRightMouseDragged:
    case NSOtherMouseDown:
    case NSOtherMouseUp:
    case NSOtherMouseDragged:
      if ([aMouseEvent subtype] == NSTabletPointEventSubtype) {
        mouseEvent->pressure = [aMouseEvent pressure];
        MOZ_ASSERT(mouseEvent->pressure >= 0.0 && mouseEvent->pressure <= 1.0);
      }
      break;

    default:
      // Don't check other NSEvents for pressure.
      break;
  }

  NS_OBJC_END_TRY_ABORT_BLOCK;
}

#pragma mark -
// NSTextInput implementation

- (void)insertText:(id)insertString
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK;

  NS_ENSURE_TRUE_VOID(mGoannaChild);

  nsAutoRetainCocoaObject kungFuDeathGrip(self);

  NSAttributedString* attrStr;
  if ([insertString isKindOfClass:[NSAttributedString class]]) {
    attrStr = static_cast<NSAttributedString*>(insertString);
  } else {
    attrStr =
      [[[NSAttributedString alloc] initWithString:insertString] autorelease];
  }

  mTextInputHandler->InsertText(attrStr);

  NS_OBJC_END_TRY_ABORT_BLOCK;
}

- (void)insertNewline:(id)sender
{
  [self insertText:@"\n"];
}

- (void) doCommandBySelector:(SEL)aSelector
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK;

  if (!mGoannaChild || !mTextInputHandler) {
    return;
  }

  const char* sel = reinterpret_cast<const char*>(aSelector);
  if (!mTextInputHandler->DoCommandBySelector(sel)) {
    [super doCommandBySelector:aSelector];
  }

  NS_OBJC_END_TRY_ABORT_BLOCK;
}

- (void) setMarkedText:(id)aString selectedRange:(NSRange)selRange
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK;

  NS_ENSURE_TRUE_VOID(mTextInputHandler);

  nsAutoRetainCocoaObject kungFuDeathGrip(self);

  NSAttributedString* attrStr;
  if ([aString isKindOfClass:[NSAttributedString class]]) {
    attrStr = static_cast<NSAttributedString*>(aString);
  } else {
    attrStr = [[[NSAttributedString alloc] initWithString:aString] autorelease];
  }

  mTextInputHandler->SetMarkedText(attrStr, selRange);

  NS_OBJC_END_TRY_ABORT_BLOCK;
}

- (void) unmarkText
{
  NS_ENSURE_TRUE(mTextInputHandler, );
  mTextInputHandler->CommitIMEComposition();
}

- (BOOL) hasMarkedText
{
  NS_ENSURE_TRUE(mTextInputHandler, NO);
  return mTextInputHandler->HasMarkedText();
}

- (BOOL)shouldZoomOnDoubleClick
{
  if ([NSWindow respondsToSelector:@selector(_shouldZoomOnDoubleClick)]) {
    return [NSWindow _shouldZoomOnDoubleClick];
  }
  return nsCocoaFeatures::OnYosemiteOrLater();
}

- (BOOL)shouldMinimizeOnTitlebarDoubleClick
{
  NSString *MDAppleMiniaturizeOnDoubleClickKey =
                                      @"AppleMiniaturizeOnDoubleClick";
  NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
  bool shouldMinimize = [[userDefaults
          objectForKey:MDAppleMiniaturizeOnDoubleClickKey] boolValue];

  return shouldMinimize;
}

- (NSInteger) conversationIdentifier
{
  NS_ENSURE_TRUE(mTextInputHandler, reinterpret_cast<NSInteger>(self));
  return mTextInputHandler->ConversationIdentifier();
}

- (NSAttributedString *) attributedSubstringFromRange:(NSRange)theRange
{
  NS_ENSURE_TRUE(mTextInputHandler, nil);
  return mTextInputHandler->GetAttributedSubstringFromRange(theRange);
}

- (NSRange) markedRange
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_RETURN;

  NS_ENSURE_TRUE(mTextInputHandler, NSMakeRange(NSNotFound, 0));
  return mTextInputHandler->MarkedRange();

  NS_OBJC_END_TRY_ABORT_BLOCK_RETURN(NSMakeRange(0, 0));
}

- (NSRange) selectedRange
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_RETURN;

  NS_ENSURE_TRUE(mTextInputHandler, NSMakeRange(NSNotFound, 0));
  return mTextInputHandler->SelectedRange();

  NS_OBJC_END_TRY_ABORT_BLOCK_RETURN(NSMakeRange(0, 0));
}

- (BOOL)drawsVerticallyForCharacterAtIndex:(NSUInteger)charIndex
{
  NS_ENSURE_TRUE(mTextInputHandler, NO);
  if (charIndex == NSNotFound) {
    return NO;
  }
  return mTextInputHandler->DrawsVerticallyForCharacterAtIndex(charIndex);
}

- (NSRect) firstRectForCharacterRange:(NSRange)theRange
{
  NSRect rect;
  NS_ENSURE_TRUE(mTextInputHandler, rect);
  return mTextInputHandler->FirstRectForCharacterRange(theRange);
}

- (NSUInteger)characterIndexForPoint:(NSPoint)thePoint
{
  NS_ENSURE_TRUE(mTextInputHandler, 0);
  return mTextInputHandler->CharacterIndexForPoint(thePoint);
}

- (NSArray*) validAttributesForMarkedText
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_NIL;

  NS_ENSURE_TRUE(mTextInputHandler, [NSArray array]);
  return mTextInputHandler->GetValidAttributesForMarkedText();

  NS_OBJC_END_TRY_ABORT_BLOCK_NIL;
}

#pragma mark -
// NSTextInputClient implementation

- (void)insertText:(id)aString replacementRange:(NSRange)replacementRange
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK;

  NS_ENSURE_TRUE_VOID(mGoannaChild);

  nsAutoRetainCocoaObject kungFuDeathGrip(self);

  NSAttributedString* attrStr;
  if ([aString isKindOfClass:[NSAttributedString class]]) {
    attrStr = static_cast<NSAttributedString*>(aString);
  } else {
    attrStr = [[[NSAttributedString alloc] initWithString:aString] autorelease];
  }

  mTextInputHandler->InsertText(attrStr, &replacementRange);

  NS_OBJC_END_TRY_ABORT_BLOCK;
}

- (void)setMarkedText:(id)aString selectedRange:(NSRange)selectedRange
                               replacementRange:(NSRange)replacementRange
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK;

  NS_ENSURE_TRUE_VOID(mTextInputHandler);

  nsAutoRetainCocoaObject kungFuDeathGrip(self);

  NSAttributedString* attrStr;
  if ([aString isKindOfClass:[NSAttributedString class]]) {
    attrStr = static_cast<NSAttributedString*>(aString);
  } else {
    attrStr = [[[NSAttributedString alloc] initWithString:aString] autorelease];
  }

  mTextInputHandler->SetMarkedText(attrStr, selectedRange, &replacementRange);

  NS_OBJC_END_TRY_ABORT_BLOCK;
}

- (NSAttributedString*)attributedSubstringForProposedRange:(NSRange)aRange
                                        actualRange:(NSRangePointer)actualRange
{
  NS_ENSURE_TRUE(mTextInputHandler, nil);
  return mTextInputHandler->GetAttributedSubstringFromRange(aRange,
                                                            actualRange);
}

- (NSRect)firstRectForCharacterRange:(NSRange)aRange
                         actualRange:(NSRangePointer)actualRange
{
  NS_ENSURE_TRUE(mTextInputHandler, NSMakeRect(0.0, 0.0, 0.0, 0.0));
  return mTextInputHandler->FirstRectForCharacterRange(aRange, actualRange);
}

- (NSInteger)windowLevel
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_RETURN;

  NS_ENSURE_TRUE(mTextInputHandler, [[self window] level]);
  return mTextInputHandler->GetWindowLevel();

  NS_OBJC_END_TRY_ABORT_BLOCK_RETURN(NSNormalWindowLevel);
}

#pragma mark -

// This is a private API that Cocoa uses.
// Cocoa will call this after the menu system returns "NO" for "performKeyEquivalent:".
// We want all they key events we can get so just return YES. In particular, this fixes
// ctrl-tab - we don't get a "keyDown:" call for that without this.
- (BOOL)_wantsKeyDownForEvent:(NSEvent*)event
{
  return YES;
}

- (NSEvent*)lastKeyDownEvent
{
  return mLastKeyDownEvent;
}

- (void)keyDown:(NSEvent*)theEvent
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK;

  [mLastKeyDownEvent release];
  mLastKeyDownEvent = [theEvent retain];

  // Weird things can happen on keyboard input if the key window isn't in the
  // current space.  For example see bug 1056251.  To get around this, always
  // make sure that, if our window is key, it's also made frontmost.  Doing
  // this automatically switches to whatever space our window is in.  Safari
  // does something similar.  Our window should normally always be key --
  // otherwise why is the OS sending us a key down event?  But it's just
  // possible we're in Goanna's hidden window, so we check first.
  NSWindow *viewWindow = [self window];
  if (viewWindow && [viewWindow isKeyWindow]) {
    [viewWindow orderWindow:NSWindowAbove relativeTo:0];
  }

#if !defined(RELEASE_BUILD) || defined(DEBUG)
  if (mGoannaChild && mTextInputHandler && mTextInputHandler->IsFocused()) {
    if (mGoannaChild->GetInputContext().IsPasswordEditor() &&
               !TextInputHandler::IsSecureEventInputEnabled()) {
      #define CRASH_MESSAGE "A password editor has focus, but not in secure input mode"
      MOZ_CRASH(CRASH_MESSAGE);
      #undef CRASH_MESSAGE
    } else if (!mGoannaChild->GetInputContext().IsPasswordEditor() &&
               TextInputHandler::IsSecureEventInputEnabled()) {
      #define CRASH_MESSAGE "A non-password editor has focus, but in secure input mode"
      MOZ_CRASH(CRASH_MESSAGE);
      #undef CRASH_MESSAGE
    }
  }
#endif // #if !defined(RELEASE_BUILD) || defined(DEBUG)

  nsAutoRetainCocoaObject kungFuDeathGrip(self);
  bool handled = false;
  if (mGoannaChild && mTextInputHandler) {
    handled = mTextInputHandler->HandleKeyDownEvent(theEvent);
  }

  // We always allow keyboard events to propagate to keyDown: but if they are not
  // handled we give special Application menu items a chance to act.
  if (!handled && sApplicationMenu) {
    [sApplicationMenu performKeyEquivalent:theEvent];
  }

  NS_OBJC_END_TRY_ABORT_BLOCK;
}

- (void)keyUp:(NSEvent*)theEvent
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK;

  NS_ENSURE_TRUE(mGoannaChild, );

  nsAutoRetainCocoaObject kungFuDeathGrip(self);

  mTextInputHandler->HandleKeyUpEvent(theEvent);

  NS_OBJC_END_TRY_ABORT_BLOCK;
}

- (void)flagsChanged:(NSEvent*)theEvent
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK;

  NS_ENSURE_TRUE(mGoannaChild, );

  nsAutoRetainCocoaObject kungFuDeathGrip(self);
  mTextInputHandler->HandleFlagsChanged(theEvent);

  NS_OBJC_END_TRY_ABORT_BLOCK;
}

- (BOOL) isFirstResponder
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_RETURN;

  NSResponder* resp = [[self window] firstResponder];
  return (resp == (NSResponder*)self);

  NS_OBJC_END_TRY_ABORT_BLOCK_RETURN(NO);
}

- (BOOL)isDragInProgress
{
  if (!mDragService)
    return NO;

  nsCOMPtr<nsIDragSession> dragSession;
  mDragService->GetCurrentSession(getter_AddRefs(dragSession));
  return dragSession != nullptr;
}

- (BOOL)inactiveWindowAcceptsMouseEvent:(NSEvent*)aEvent
{
  // If we're being destroyed assume the default -- return YES.
  if (!mGoannaChild)
    return YES;

  WidgetMouseEvent goannaEvent(true, NS_MOUSE_ACTIVATE, mGoannaChild,
                              WidgetMouseEvent::eReal);
  [self convertCocoaMouseEvent:aEvent toGoannaEvent:&goannaEvent];
  return !mGoannaChild->DispatchWindowEvent(goannaEvent);
}

// We must always call through to our superclass, even when mGoannaChild is
// nil -- otherwise the keyboard focus can end up in the wrong NSView.
- (BOOL)becomeFirstResponder
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_RETURN;

  return [super becomeFirstResponder];

  NS_OBJC_END_TRY_ABORT_BLOCK_RETURN(YES);
}

- (void)viewsWindowDidBecomeKey
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK;

  if (!mGoannaChild)
    return;

  nsAutoRetainCocoaObject kungFuDeathGrip(self);

  // check to see if the window implements the mozWindow protocol. This
  // allows embedders to avoid re-entrant calls to -makeKeyAndOrderFront,
  // which can happen because these activate calls propagate out
  // to the embedder via nsIEmbeddingSiteWindow::SetFocus().
  BOOL isMozWindow = [[self window] respondsToSelector:@selector(setSuppressMakeKeyFront:)];
  if (isMozWindow)
    [[self window] setSuppressMakeKeyFront:YES];

  nsIWidgetListener* listener = mGoannaChild->GetWidgetListener();
  if (listener)
    listener->WindowActivated();

  if (isMozWindow)
    [[self window] setSuppressMakeKeyFront:NO];

  NS_OBJC_END_TRY_ABORT_BLOCK;
}

- (void)viewsWindowDidResignKey
{
  if (!mGoannaChild)
    return;

  nsAutoRetainCocoaObject kungFuDeathGrip(self);

  nsIWidgetListener* listener = mGoannaChild->GetWidgetListener();
  if (listener)
    listener->WindowDeactivated();
}

// If the call to removeFromSuperview isn't delayed from nsChildView::
// TearDownView(), the NSView hierarchy might get changed during calls to
// [ChildView drawRect:], which leads to "beyond bounds" exceptions in
// NSCFArray.  For more info see bmo bug 373122.  Apple's docs claim that
// removeFromSuperviewWithoutNeedingDisplay "can be safely invoked during
// display" (whatever "display" means).  But it's _not_ true that it can be
// safely invoked during calls to [NSView drawRect:].  We use
// removeFromSuperview here because there's no longer any danger of being
// "invoked during display", and because doing do clears up bmo bug 384343.
- (void)delayedTearDown
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK;

  [self removeFromSuperview];
  [self release];

  NS_OBJC_END_TRY_ABORT_BLOCK;
}

#pragma mark -

// drag'n'drop stuff
#define kDragServiceContractID "@mozilla.org/widget/dragservice;1"

- (NSDragOperation)dragOperationForSession:(nsIDragSession*)aDragSession
{
  uint32_t dragAction;
  aDragSession->GetDragAction(&dragAction);
  if (nsIDragService::DRAGDROP_ACTION_LINK & dragAction)
    return NSDragOperationLink;
  if (nsIDragService::DRAGDROP_ACTION_COPY & dragAction)
    return NSDragOperationCopy;
  if (nsIDragService::DRAGDROP_ACTION_MOVE & dragAction)
    return NSDragOperationGeneric;
  return NSDragOperationNone;
}

- (nsIntPoint)convertWindowCoordinates:(NSPoint)aPoint
{
  if (!mGoannaChild) {
    return nsIntPoint(0, 0);
  }

  NSPoint localPoint = [self convertPoint:aPoint fromView:nil];
  return mGoannaChild->CocoaPointsToDevPixels(localPoint);
}

- (APZCTreeManager*)apzctm
{
  return mGoannaChild ? mGoannaChild->APZCTM() : nullptr;
}

// This is a utility function used by NSView drag event methods
// to send events. It contains all of the logic needed for Goanna
// dragging to work. Returns the appropriate cocoa drag operation code.
- (NSDragOperation)doDragAction:(uint32_t)aMessage sender:(id)aSender
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_RETURN;

  if (!mGoannaChild)
    return NSDragOperationNone;

  PR_LOG(sCocoaLog, PR_LOG_ALWAYS, ("ChildView doDragAction: entered\n"));

  if (!mDragService) {
    CallGetService(kDragServiceContractID, &mDragService);
    NS_ASSERTION(mDragService, "Couldn't get a drag service - big problem!");
    if (!mDragService)
      return NSDragOperationNone;
  }

  if (aMessage == NS_DRAGDROP_ENTER)
    mDragService->StartDragSession();

  nsCOMPtr<nsIDragSession> dragSession;
  mDragService->GetCurrentSession(getter_AddRefs(dragSession));
  if (dragSession) {
    if (aMessage == NS_DRAGDROP_OVER) {
      // fire the drag event at the source. Just ignore whether it was
      // cancelled or not as there isn't actually a means to stop the drag
      mDragService->FireDragEventAtSource(NS_DRAGDROP_DRAG);
      dragSession->SetCanDrop(false);
    }
    else if (aMessage == NS_DRAGDROP_DROP) {
      // We make the assumption that the dragOver handlers have correctly set
      // the |canDrop| property of the Drag Session.
      bool canDrop = false;
      if (!NS_SUCCEEDED(dragSession->GetCanDrop(&canDrop)) || !canDrop) {
        [self doDragAction:NS_DRAGDROP_EXIT sender:aSender];

        nsCOMPtr<nsIDOMNode> sourceNode;
        dragSession->GetSourceNode(getter_AddRefs(sourceNode));
        if (!sourceNode) {
          mDragService->EndDragSession(false);
        }
        return NSDragOperationNone;
      }
    }

    unsigned int modifierFlags = [[NSApp currentEvent] modifierFlags];
    uint32_t action = nsIDragService::DRAGDROP_ACTION_MOVE;
    // force copy = option, alias = cmd-option, default is move
    if (modifierFlags & NSAlternateKeyMask) {
      if (modifierFlags & NSCommandKeyMask)
        action = nsIDragService::DRAGDROP_ACTION_LINK;
      else
        action = nsIDragService::DRAGDROP_ACTION_COPY;
    }
    dragSession->SetDragAction(action);
  }

  // set up goanna event
  WidgetDragEvent goannaEvent(true, aMessage, mGoannaChild);
  nsCocoaUtils::InitInputEvent(goannaEvent, [NSApp currentEvent]);

  // Use our own coordinates in the goanna event.
  // Convert event from goanna global coords to goanna view coords.
  NSPoint draggingLoc = [aSender draggingLocation];

  goannaEvent.refPoint = LayoutDeviceIntPoint::FromUntyped(
    [self convertWindowCoordinates:draggingLoc]);

  nsAutoRetainCocoaObject kungFuDeathGrip(self);
  mGoannaChild->DispatchWindowEvent(goannaEvent);
  if (!mGoannaChild)
    return NSDragOperationNone;

  if (dragSession) {
    switch (aMessage) {
      case NS_DRAGDROP_ENTER:
      case NS_DRAGDROP_OVER:
        return [self dragOperationForSession:dragSession];
      case NS_DRAGDROP_EXIT:
      case NS_DRAGDROP_DROP: {
        nsCOMPtr<nsIDOMNode> sourceNode;
        dragSession->GetSourceNode(getter_AddRefs(sourceNode));
        if (!sourceNode) {
          // We're leaving a window while doing a drag that was
          // initiated in a different app. End the drag session,
          // since we're done with it for now (until the user
          // drags back into mozilla).
          mDragService->EndDragSession(false);
        }
      }
    }
  }

  return NSDragOperationGeneric;

  NS_OBJC_END_TRY_ABORT_BLOCK_RETURN(NSDragOperationNone);
}

- (NSDragOperation)draggingEntered:(id <NSDraggingInfo>)sender
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_RETURN;

  PR_LOG(sCocoaLog, PR_LOG_ALWAYS, ("ChildView draggingEntered: entered\n"));

  // there should never be a globalDragPboard when "draggingEntered:" is
  // called, but just in case we'll take care of it here.
  [globalDragPboard release];

  // Set the global drag pasteboard that will be used for this drag session.
  // This will be set back to nil when the drag session ends (mouse exits
  // the view or a drop happens within the view).
  globalDragPboard = [[sender draggingPasteboard] retain];

  return [self doDragAction:NS_DRAGDROP_ENTER sender:sender];

  NS_OBJC_END_TRY_ABORT_BLOCK_RETURN(NSDragOperationNone);
}

- (NSDragOperation)draggingUpdated:(id <NSDraggingInfo>)sender
{
  PR_LOG(sCocoaLog, PR_LOG_ALWAYS, ("ChildView draggingUpdated: entered\n"));

  return [self doDragAction:NS_DRAGDROP_OVER sender:sender];
}

- (void)draggingExited:(id <NSDraggingInfo>)sender
{
  PR_LOG(sCocoaLog, PR_LOG_ALWAYS, ("ChildView draggingExited: entered\n"));

  nsAutoRetainCocoaObject kungFuDeathGrip(self);
  [self doDragAction:NS_DRAGDROP_EXIT sender:sender];
  NS_IF_RELEASE(mDragService);
}

- (BOOL)performDragOperation:(id <NSDraggingInfo>)sender
{
  nsAutoRetainCocoaObject kungFuDeathGrip(self);
  BOOL handled = [self doDragAction:NS_DRAGDROP_DROP sender:sender] != NSDragOperationNone;
  NS_IF_RELEASE(mDragService);
  return handled;
}

// NSDraggingSource
- (void)draggedImage:(NSImage *)anImage movedTo:(NSPoint)aPoint
{
  // Get the drag service if it isn't already cached. The drag service
  // isn't cached when dragging over a different application.
  nsCOMPtr<nsIDragService> dragService = mDragService;
  if (!dragService) {
    dragService = do_GetService(kDragServiceContractID);
  }

  if (dragService) {
    NSPoint pnt = [NSEvent mouseLocation];
    FlipCocoaScreenCoordinate(pnt);
    dragService->DragMoved(NSToIntRound(pnt.x), NSToIntRound(pnt.y));
  }
}

// NSDraggingSource
- (void)draggedImage:(NSImage *)anImage endedAt:(NSPoint)aPoint operation:(NSDragOperation)operation
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK;

  gDraggedTransferables = nullptr;

  NSEvent *currentEvent = [NSApp currentEvent];
  gUserCancelledDrag = ([currentEvent type] == NSKeyDown &&
                        [currentEvent keyCode] == kVK_Escape);

  if (!mDragService) {
    CallGetService(kDragServiceContractID, &mDragService);
    NS_ASSERTION(mDragService, "Couldn't get a drag service - big problem!");
  }

  if (mDragService) {
    // set the dragend point from the current mouse location
    nsDragService* dragService = static_cast<nsDragService *>(mDragService);
    NSPoint pnt = [NSEvent mouseLocation];
    FlipCocoaScreenCoordinate(pnt);
    dragService->SetDragEndPoint(nsIntPoint(NSToIntRound(pnt.x), NSToIntRound(pnt.y)));

    // XXX: dropEffect should be updated per |operation|.
    // As things stand though, |operation| isn't well handled within "our"
    // events, that is, when the drop happens within the window: it is set
    // either to NSDragOperationGeneric or to NSDragOperationNone.
    // For that reason, it's not yet possible to override dropEffect per the
    // given OS value, and it's also unclear what's the correct dropEffect
    // value for NSDragOperationGeneric that is passed by other applications.
    // All that said, NSDragOperationNone is still reliable.
    if (operation == NSDragOperationNone) {
      nsCOMPtr<nsIDOMDataTransfer> dataTransfer;
      dragService->GetDataTransfer(getter_AddRefs(dataTransfer));
      if (dataTransfer)
        dataTransfer->SetDropEffectInt(nsIDragService::DRAGDROP_ACTION_NONE);
    }

    mDragService->EndDragSession(true);
    NS_RELEASE(mDragService);
  }

  [globalDragPboard release];
  globalDragPboard = nil;
  [gLastDragMouseDownEvent release];
  gLastDragMouseDownEvent = nil;

  NS_OBJC_END_TRY_ABORT_BLOCK;
}

// NSDraggingSource
// this is just implemented so we comply with the NSDraggingSource informal protocol
- (NSDragOperation)draggingSourceOperationMaskForLocal:(BOOL)isLocal
{
  return UINT_MAX;
}

// This method is a callback typically invoked in response to a drag ending on the desktop
// or a Findow folder window; the argument passed is a path to the drop location, to be used
// in constructing a complete pathname for the file(s) we want to create as a result of
// the drag.
- (NSArray *)namesOfPromisedFilesDroppedAtDestination:(NSURL*)dropDestination
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_NIL;

  nsresult rv;

  PR_LOG(sCocoaLog, PR_LOG_ALWAYS, ("ChildView namesOfPromisedFilesDroppedAtDestination: entering callback for promised files\n"));

  nsCOMPtr<nsIFile> targFile;
  NS_NewLocalFile(EmptyString(), true, getter_AddRefs(targFile));
  nsCOMPtr<nsILocalFileMac> macLocalFile = do_QueryInterface(targFile);
  if (!macLocalFile) {
    NS_ERROR("No Mac local file");
    return nil;
  }

  if (!NS_SUCCEEDED(macLocalFile->InitWithCFURL((CFURLRef)dropDestination))) {
    NS_ERROR("failed InitWithCFURL");
    return nil;
  }

  if (!gDraggedTransferables)
    return nil;

  uint32_t transferableCount;
  rv = gDraggedTransferables->Count(&transferableCount);
  if (NS_FAILED(rv))
    return nil;

  for (uint32_t i = 0; i < transferableCount; i++) {
    nsCOMPtr<nsISupports> genericItem;
    gDraggedTransferables->GetElementAt(i, getter_AddRefs(genericItem));
    nsCOMPtr<nsITransferable> item(do_QueryInterface(genericItem));
    if (!item) {
      NS_ERROR("no transferable");
      return nil;
    }

    item->SetTransferData(kFilePromiseDirectoryMime, macLocalFile, sizeof(nsIFile*));

    // now request the kFilePromiseMime data, which will invoke the data provider
    // If successful, the returned data is a reference to the resulting file.
    nsCOMPtr<nsISupports> fileDataPrimitive;
    uint32_t dataSize = 0;
    item->GetTransferData(kFilePromiseMime, getter_AddRefs(fileDataPrimitive), &dataSize);
  }

  NSPasteboard* generalPboard = [NSPasteboard pasteboardWithName:NSDragPboard];
  NSData* data = [generalPboard dataForType:@"application/x-moz-file-promise-dest-filename"];
  NSString* name = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  NSArray* rslt = [NSArray arrayWithObject:name];

  [name release];

  return rslt;

  NS_OBJC_END_TRY_ABORT_BLOCK_NIL;
}

#pragma mark -

// Support for the "Services" menu. We currently only support sending strings
// and HTML to system services.

- (id)validRequestorForSendType:(NSString *)sendType
                     returnType:(NSString *)returnType
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_NIL;

  // sendType contains the type of data that the service would like this
  // application to send to it.  sendType is nil if the service is not
  // requesting any data.
  //
  // returnType contains the type of data the the service would like to
  // return to this application (e.g., to overwrite the selection).
  // returnType is nil if the service will not return any data.
  //
  // The following condition thus triggers when the service expects a string
  // or HTML from us or no data at all AND when the service will either not
  // send back any data to us or will send a string or HTML back to us.

#define IsSupportedType(typeStr) ([typeStr isEqual:NSStringPboardType] || [typeStr isEqual:NSHTMLPboardType])

  id result = nil;

  if ((!sendType || IsSupportedType(sendType)) &&
      (!returnType || IsSupportedType(returnType))) {
    if (mGoannaChild) {
      // Assume that this object will be able to handle this request.
      result = self;

      // Keep the ChildView alive during this operation.
      nsAutoRetainCocoaObject kungFuDeathGrip(self);

      // Determine if there is a selection (if sending to the service).
      if (sendType) {
        WidgetQueryContentEvent event(true, NS_QUERY_CONTENT_STATE,
                                      mGoannaChild);
        // This might destroy our widget (and null out mGoannaChild).
        mGoannaChild->DispatchWindowEvent(event);
        if (!mGoannaChild || !event.mSucceeded || !event.mReply.mHasSelection)
          result = nil;
      }

      // Determine if we can paste (if receiving data from the service).
      if (mGoannaChild && returnType) {
        WidgetContentCommandEvent command(true,
                                          NS_CONTENT_COMMAND_PASTE_TRANSFERABLE,
                                          mGoannaChild, true);
        // This might possibly destroy our widget (and null out mGoannaChild).
        mGoannaChild->DispatchWindowEvent(command);
        if (!mGoannaChild || !command.mSucceeded || !command.mIsEnabled)
          result = nil;
      }
    }
  }

#undef IsSupportedType

  // Give the superclass a chance if this object will not handle this request.
  if (!result)
    result = [super validRequestorForSendType:sendType returnType:returnType];

  return result;

  NS_OBJC_END_TRY_ABORT_BLOCK_NIL;
}

- (BOOL)writeSelectionToPasteboard:(NSPasteboard *)pboard
                             types:(NSArray *)types
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_RETURN;

  nsAutoRetainCocoaObject kungFuDeathGrip(self);

  // Make sure that the service will accept strings or HTML.
  if ([types containsObject:NSStringPboardType] == NO &&
      [types containsObject:NSHTMLPboardType] == NO)
    return NO;

  // Bail out if there is no Goanna object.
  if (!mGoannaChild)
    return NO;

  // Obtain the current selection.
  WidgetQueryContentEvent event(true,
                                NS_QUERY_SELECTION_AS_TRANSFERABLE,
                                mGoannaChild);
  mGoannaChild->DispatchWindowEvent(event);
  if (!event.mSucceeded || !event.mReply.mTransferable)
    return NO;

  // Transform the transferable to an NSDictionary.
  NSDictionary* pasteboardOutputDict = nsClipboard::PasteboardDictFromTransferable(event.mReply.mTransferable);
  if (!pasteboardOutputDict)
    return NO;

  // Declare the pasteboard types.
  unsigned int typeCount = [pasteboardOutputDict count];
  NSMutableArray * types = [NSMutableArray arrayWithCapacity:typeCount];
  [types addObjectsFromArray:[pasteboardOutputDict allKeys]];
  [pboard declareTypes:types owner:nil];

  // Write the data to the pasteboard.
  for (unsigned int i = 0; i < typeCount; i++) {
    NSString* currentKey = [types objectAtIndex:i];
    id currentValue = [pasteboardOutputDict valueForKey:currentKey];

    if (currentKey == NSStringPboardType ||
        currentKey == kCorePboardType_url ||
        currentKey == kCorePboardType_urld ||
        currentKey == kCorePboardType_urln) {
      [pboard setString:currentValue forType:currentKey];
    } else if (currentKey == NSHTMLPboardType) {
      [pboard setString:(nsClipboard::WrapHtmlForSystemPasteboard(currentValue)) forType:currentKey];
    } else if (currentKey == NSTIFFPboardType) {
      [pboard setData:currentValue forType:currentKey];
    } else if (currentKey == NSFilesPromisePboardType) {
      [pboard setPropertyList:currentValue forType:currentKey];
    }
  }

  return YES;

  NS_OBJC_END_TRY_ABORT_BLOCK_RETURN(NO);
}

// Called if the service wants us to replace the current selection.
- (BOOL)readSelectionFromPasteboard:(NSPasteboard *)pboard
{
  nsresult rv;
  nsCOMPtr<nsITransferable> trans = do_CreateInstance("@mozilla.org/widget/transferable;1", &rv);
  if (NS_FAILED(rv))
    return NO;
  trans->Init(nullptr);

  trans->AddDataFlavor(kUnicodeMime);
  trans->AddDataFlavor(kHTMLMime);

  rv = nsClipboard::TransferableFromPasteboard(trans, pboard);
  if (NS_FAILED(rv))
    return NO;

  NS_ENSURE_TRUE(mGoannaChild, false);

  WidgetContentCommandEvent command(true,
                                    NS_CONTENT_COMMAND_PASTE_TRANSFERABLE,
                                    mGoannaChild);
  command.mTransferable = trans;
  mGoannaChild->DispatchWindowEvent(command);

  return command.mSucceeded && command.mIsEnabled;
}

#pragma mark -

#ifdef ACCESSIBILITY

/* Every ChildView has a corresponding mozDocAccessible object that is doing all
   the heavy lifting. The topmost ChildView corresponds to a mozRootAccessible
   object.

   All ChildView needs to do is to route all accessibility calls (from the NSAccessibility APIs)
   down to its object, pretending that they are the same.
*/
- (id<mozAccessible>)accessible
{
  if (!mGoannaChild)
    return nil;

  id<mozAccessible> nativeAccessible = nil;

  nsAutoRetainCocoaObject kungFuDeathGrip(self);
  nsCOMPtr<nsIWidget> kungFuDeathGrip2(mGoannaChild);
  nsRefPtr<a11y::Accessible> accessible = mGoannaChild->GetDocumentAccessible();
  if (!accessible)
    return nil;

  accessible->GetNativeInterface((void**)&nativeAccessible);

#ifdef DEBUG_hakan
  NSAssert(![nativeAccessible isExpired], @"native acc is expired!!!");
#endif

  return nativeAccessible;
}

/* Implementation of formal mozAccessible formal protocol (enabling mozViews
   to talk to mozAccessible objects in the accessibility module). */

- (BOOL)hasRepresentedView
{
  return YES;
}

- (id)representedView
{
  return self;
}

- (BOOL)isRoot
{
  return [[self accessible] isRoot];
}

#ifdef DEBUG
- (void)printHierarchy
{
  [[self accessible] printHierarchy];
}
#endif

#pragma mark -

// general

- (BOOL)accessibilityIsIgnored
{
  if (!mozilla::a11y::ShouldA11yBeEnabled())
    return [super accessibilityIsIgnored];

  return [[self accessible] accessibilityIsIgnored];
}

- (id)accessibilityHitTest:(NSPoint)point
{
  if (!mozilla::a11y::ShouldA11yBeEnabled())
    return [super accessibilityHitTest:point];

  return [[self accessible] accessibilityHitTest:point];
}

- (id)accessibilityFocusedUIElement
{
  if (!mozilla::a11y::ShouldA11yBeEnabled())
    return [super accessibilityFocusedUIElement];

  return [[self accessible] accessibilityFocusedUIElement];
}

// actions

- (NSArray*)accessibilityActionNames
{
  if (!mozilla::a11y::ShouldA11yBeEnabled())
    return [super accessibilityActionNames];

  return [[self accessible] accessibilityActionNames];
}

- (NSString*)accessibilityActionDescription:(NSString*)action
{
  if (!mozilla::a11y::ShouldA11yBeEnabled())
    return [super accessibilityActionDescription:action];

  return [[self accessible] accessibilityActionDescription:action];
}

- (void)accessibilityPerformAction:(NSString*)action
{
  if (!mozilla::a11y::ShouldA11yBeEnabled())
    return [super accessibilityPerformAction:action];

  return [[self accessible] accessibilityPerformAction:action];
}

// attributes

- (NSArray*)accessibilityAttributeNames
{
  if (!mozilla::a11y::ShouldA11yBeEnabled())
    return [super accessibilityAttributeNames];

  return [[self accessible] accessibilityAttributeNames];
}

- (BOOL)accessibilityIsAttributeSettable:(NSString*)attribute
{
  if (!mozilla::a11y::ShouldA11yBeEnabled())
    return [super accessibilityIsAttributeSettable:attribute];

  return [[self accessible] accessibilityIsAttributeSettable:attribute];
}

- (id)accessibilityAttributeValue:(NSString*)attribute
{
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_NIL;

  if (!mozilla::a11y::ShouldA11yBeEnabled())
    return [super accessibilityAttributeValue:attribute];

  id<mozAccessible> accessible = [self accessible];

  // if we're the root (topmost) accessible, we need to return our native AXParent as we
  // traverse outside to the hierarchy of whoever embeds us. thus, fall back on NSView's
  // default implementation for this attribute.
  if ([attribute isEqualToString:NSAccessibilityParentAttribute] && [accessible isRoot]) {
    id parentAccessible = [super accessibilityAttributeValue:attribute];
    return parentAccessible;
  }

  return [accessible accessibilityAttributeValue:attribute];

  NS_OBJC_END_TRY_ABORT_BLOCK_NIL;
}

#endif /* ACCESSIBILITY */

@end

#pragma mark -

void
ChildViewMouseTracker::OnDestroyView(ChildView* aView)
{
  if (sLastMouseEventView == aView) {
    sLastMouseEventView = nil;
    [sLastMouseMoveEvent release];
    sLastMouseMoveEvent = nil;
  }
}

void
ChildViewMouseTracker::OnDestroyWindow(NSWindow* aWindow)
{
  if (sWindowUnderMouse == aWindow) {
    sWindowUnderMouse = nil;
  }
}

void
ChildViewMouseTracker::MouseEnteredWindow(NSEvent* aEvent)
{
  sWindowUnderMouse = [aEvent window];
  ReEvaluateMouseEnterState(aEvent);
}

void
ChildViewMouseTracker::MouseExitedWindow(NSEvent* aEvent)
{
  if (sWindowUnderMouse == [aEvent window]) {
    sWindowUnderMouse = nil;
    ReEvaluateMouseEnterState(aEvent);
  }
}

void
ChildViewMouseTracker::ReEvaluateMouseEnterState(NSEvent* aEvent, ChildView* aOldView)
{
  ChildView* oldView = aOldView ? aOldView : sLastMouseEventView;
  sLastMouseEventView = ViewForEvent(aEvent);
  if (sLastMouseEventView != oldView) {
    // Send enter and / or exit events.
    WidgetMouseEvent::exitType type =
      [sLastMouseEventView window] == [oldView window] ?
        WidgetMouseEvent::eChild : WidgetMouseEvent::eTopLevel;
    [oldView sendMouseEnterOrExitEvent:aEvent enter:NO type:type];
    // After the cursor exits the window set it to a visible regular arrow cursor.
    if (type == WidgetMouseEvent::eTopLevel) {
      [[nsCursorManager sharedInstance] setCursor:eCursor_standard];
    }
    [sLastMouseEventView sendMouseEnterOrExitEvent:aEvent enter:YES type:type];
  }
}

void
ChildViewMouseTracker::ResendLastMouseMoveEvent()
{
  if (sLastMouseMoveEvent) {
    MouseMoved(sLastMouseMoveEvent);
  }
}

void
ChildViewMouseTracker::MouseMoved(NSEvent* aEvent)
{
  MouseEnteredWindow(aEvent);
  [sLastMouseEventView handleMouseMoved:aEvent];
  if (sLastMouseMoveEvent != aEvent) {
    [sLastMouseMoveEvent release];
    sLastMouseMoveEvent = [aEvent retain];
  }
}

void
ChildViewMouseTracker::MouseScrolled(NSEvent* aEvent)
{
  if (!nsCocoaUtils::IsMomentumScrollEvent(aEvent)) {
    // Store the position so we can pin future momentum scroll events.
    sLastScrollEventScreenLocation = nsCocoaUtils::ScreenLocationForEvent(aEvent);
  }
}

ChildView*
ChildViewMouseTracker::ViewForEvent(NSEvent* aEvent)
{
  NSWindow* window = sWindowUnderMouse;
  if (!window)
    return nil;

  NSPoint windowEventLocation = nsCocoaUtils::EventLocationForWindow(aEvent, window);
  NSView* view = [[[window contentView] superview] hitTest:windowEventLocation];

  if (![view isKindOfClass:[ChildView class]])
    return nil;

  ChildView* childView = (ChildView*)view;
  // If childView is being destroyed return nil.
  if (![childView widget])
    return nil;
  return WindowAcceptsEvent(window, aEvent, childView) ? childView : nil;
}

BOOL
ChildViewMouseTracker::WindowAcceptsEvent(NSWindow* aWindow, NSEvent* aEvent,
                                          ChildView* aView, BOOL aIsClickThrough)
{
  // Right mouse down events may get through to all windows, even to a top level
  // window with an open sheet.
  if (!aWindow || [aEvent type] == NSRightMouseDown)
    return YES;

  id delegate = [aWindow delegate];
  if (!delegate || ![delegate isKindOfClass:[WindowDelegate class]])
    return YES;

  nsIWidget *windowWidget = [(WindowDelegate *)delegate goannaWidget];
  if (!windowWidget)
    return YES;

  NSWindow* topLevelWindow = nil;

  switch (windowWidget->WindowType()) {
    case eWindowType_popup:
      // If this is a context menu, it won't have a parent. So we'll always
      // accept mouse move events on context menus even when none of our windows
      // is active, which is the right thing to do.
      // For panels, the parent window is the XUL window that owns the panel.
      return WindowAcceptsEvent([aWindow parentWindow], aEvent, aView, aIsClickThrough);

    case eWindowType_toplevel:
    case eWindowType_dialog:
      if ([aWindow attachedSheet])
        return NO;

      topLevelWindow = aWindow;
      break;
    case eWindowType_sheet: {
      nsIWidget* parentWidget = windowWidget->GetSheetWindowParent();
      if (!parentWidget)
        return YES;

      topLevelWindow = (NSWindow*)parentWidget->GetNativeData(NS_NATIVE_WINDOW);
      break;
    }

    default:
      return YES;
  }

  if (!topLevelWindow ||
      ([topLevelWindow isMainWindow] && !aIsClickThrough) ||
      [aEvent type] == NSOtherMouseDown ||
      (([aEvent modifierFlags] & NSCommandKeyMask) != 0 &&
       [aEvent type] != NSMouseMoved))
    return YES;

  // If we're here then we're dealing with a left click or mouse move on an
  // inactive window or something similar. Ask Goanna what to do.
  return [aView inactiveWindowAcceptsMouseEvent:aEvent];
}

#pragma mark -

@interface EventThreadRunner(Private)
- (void)runEventThread;
- (void)shutdownAndReleaseCalledOnEventThread;
- (void)shutdownAndReleaseCalledOnAnyThread;
- (void)handleEvent:(CGEventRef)cgEvent type:(CGEventType)type;
@end

static EventThreadRunner* sEventThreadRunner = nil;

@implementation EventThreadRunner

+ (void)start
{
  sEventThreadRunner = [[EventThreadRunner alloc] init];
}

+ (void)stop
{
  if (sEventThreadRunner) {
    [sEventThreadRunner shutdownAndReleaseCalledOnAnyThread];
    sEventThreadRunner = nil;
  }
}

- (id)init
{
  if ((self = [super init])) {
    mThread = nil;
    [NSThread detachNewThreadSelector:@selector(runEventThread)
                             toTarget:self
                           withObject:nil];
  }
  return self;
}

static CGEventRef
HandleEvent(CGEventTapProxy aProxy, CGEventType aType,
            CGEventRef aEvent, void* aClosure)
{
  [(EventThreadRunner*)aClosure handleEvent:aEvent type:aType];
  return aEvent;
}

- (void)runEventThread
{
  char aLocal;
  profiler_register_thread("APZC Event Thread", &aLocal);
  PR_SetCurrentThreadName("APZC Event Thread");

  mThread = [NSThread currentThread];
  ProcessSerialNumber currentProcess;
  GetCurrentProcess(&currentProcess);
  CFMachPortRef eventPort =
    CGEventTapCreateForPSN(&currentProcess,
                           kCGHeadInsertEventTap,
                           kCGEventTapOptionListenOnly,
                           CGEventMaskBit(kCGEventScrollWheel),
                           HandleEvent,
                           self);
  CFRunLoopSourceRef eventPortSource =
    CFMachPortCreateRunLoopSource(kCFAllocatorSystemDefault, eventPort, 0);
  CFRunLoopAddSource(CFRunLoopGetCurrent(), eventPortSource, kCFRunLoopCommonModes);
  CFRunLoopRun();
  CFRunLoopRemoveSource(CFRunLoopGetCurrent(), eventPortSource, kCFRunLoopCommonModes);
  CFRelease(eventPortSource);
  CFRelease(eventPort);
  [self release];
}

- (void)shutdownAndReleaseCalledOnEventThread
{
  CFRunLoopStop(CFRunLoopGetCurrent());
}

- (void)shutdownAndReleaseCalledOnAnyThread
{
  [self performSelector:@selector(shutdownAndReleaseCalledOnEventThread) onThread:mThread withObject:nil waitUntilDone:NO];
}

static const CGEventField kCGWindowNumberField = (const CGEventField) 51;

// Called on scroll thread
- (void)handleEvent:(CGEventRef)cgEvent type:(CGEventType)type
{
  if (type != kCGEventScrollWheel) {
    return;
  }

  int windowNumber = CGEventGetIntegerValueField(cgEvent, kCGWindowNumberField);
  NSWindow* window = [NSApp windowWithWindowNumber:windowNumber];
  if (!window || ![window isKindOfClass:[BaseWindow class]]) {
    return;
  }

  ChildView* childView = [(BaseWindow*)window mainChildView];
  [childView handleAsyncScrollEvent:cgEvent ofType:type];
}

@end

@interface NSView (MethodSwizzling)
- (BOOL)nsChildView_NSView_mouseDownCanMoveWindow;
@end

@implementation NSView (MethodSwizzling)

// All top-level browser windows belong to the ToolbarWindow class and have
// NSTexturedBackgroundWindowMask turned on in their "style" (see particularly
// [ToolbarWindow initWithContentRect:...] in nsCocoaWindow.mm).  This style
// normally means the window "may be moved by clicking and dragging anywhere
// in the window background", but we've suppressed this by giving the
// ChildView class a mouseDownCanMoveWindow method that always returns NO.
// Normally a ToolbarWindow's contentView (not a ChildView) returns YES when
// NSTexturedBackgroundWindowMask is turned on.  But normally this makes no
// difference.  However, under some (probably very unusual) circumstances
// (and only on Leopard) it *does* make a difference -- for example it
// triggers bmo bugs 431902 and 476393.  So here we make sure that a
// ToolbarWindow's contentView always returns NO from the
// mouseDownCanMoveWindow method.
- (BOOL)nsChildView_NSView_mouseDownCanMoveWindow
{
  NSWindow *ourWindow = [self window];
  NSView *contentView = [ourWindow contentView];
  if ([ourWindow isKindOfClass:[ToolbarWindow class]] && (self == contentView))
    return [ourWindow isMovableByWindowBackground];
  return [self nsChildView_NSView_mouseDownCanMoveWindow];
}

@end

#ifdef __LP64__
// When using blocks, at least on OS X 10.7, the OS sometimes calls
// +[NSEvent removeMonitor:] more than once on a single event monitor, which
// causes crashes.  See bug 678607.  We hook these methods to work around
// the problem.
@interface NSEvent (MethodSwizzling)
+ (id)nsChildView_NSEvent_addLocalMonitorForEventsMatchingMask:(unsigned long long)mask handler:(id)block;
+ (void)nsChildView_NSEvent_removeMonitor:(id)eventMonitor;
@end

// This is a local copy of the AppKit frameworks sEventObservers hashtable.
// It only stores "local monitors".  We use it to ensure that +[NSEvent
// removeMonitor:] is never called more than once on the same local monitor.
static NSHashTable *sLocalEventObservers = nil;

@implementation NSEvent (MethodSwizzling)

+ (id)nsChildView_NSEvent_addLocalMonitorForEventsMatchingMask:(unsigned long long)mask handler:(id)block
{
  if (!sLocalEventObservers) {
    sLocalEventObservers = [[NSHashTable hashTableWithOptions:
      NSHashTableStrongMemory | NSHashTableObjectPointerPersonality] retain];
  }
  id retval =
    [self nsChildView_NSEvent_addLocalMonitorForEventsMatchingMask:mask handler:block];
  if (sLocalEventObservers && retval && ![sLocalEventObservers containsObject:retval]) {
    [sLocalEventObservers addObject:retval];
  }
  return retval;
}

+ (void)nsChildView_NSEvent_removeMonitor:(id)eventMonitor
{
  if (sLocalEventObservers && [eventMonitor isKindOfClass: ::NSClassFromString(@"_NSLocalEventObserver")]) {
    if (![sLocalEventObservers containsObject:eventMonitor]) {
      return;
    }
    [sLocalEventObservers removeObject:eventMonitor];
  }
  [self nsChildView_NSEvent_removeMonitor:eventMonitor];
}

@end
#endif // #ifdef __LP64__