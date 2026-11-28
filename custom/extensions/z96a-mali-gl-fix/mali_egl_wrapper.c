/*
 * Z96A libmali EGL wrapper.
 *
 * The Rockchip libmali blob (gbm-wayland-gbm variant) is missing the
 * EGL_EXT_device_query / EGL_MESA_query_driver entry points that Firefox's
 * glxtest requires (eglQueryDeviceStringEXT is a hard requirement,
 * "libEGL missing methods for GL test" otherwise).  Mutter also warns about
 * eglQueryDisplayAttribEXT not being resolvable.
 *
 * This wrapper replaces mali-egl/libEGL.so.1: it forwards every EGL call to
 * the real blob (DT_NEEDED libmali.so.1) and additionally implements the
 * missing symbols on top of the device the blob actually renders/allocates
 * on (/dev/dri/renderD128, the rockchip-drm render node used by the mali
 * GBM backend and the rockchip-mpp VA-API driver).
 *
 * Build on device:
 *   gcc -shared -fPIC -O2 -o libEGL.so.1.z96a mali_egl_wrapper.c -ldl \
 *       -L/usr/lib/aarch64-linux-gnu/mali-egl -lmali \
 *       -Wl,--no-as-needed -Wl,-soname,libEGL.so.1
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

typedef void *EGLDisplay;
typedef void *EGLSurface;
typedef void *EGLContext;
typedef void *EGLConfig;
typedef void *EGLSync;
typedef void *EGLImage;
typedef void *EGLDeviceEXT;
typedef unsigned int EGLBoolean;
typedef int EGLint;
typedef intptr_t EGLAttrib;
typedef unsigned int EGLenum;
typedef unsigned long long EGLTime;
typedef void *EGLNativeDisplayType;
typedef void *EGLNativeWindowType;
typedef void *EGLNativePixmapType;

#ifndef EGL_TRUE
#define EGL_TRUE 1
#define EGL_FALSE 0
#endif
#define EGL_DEVICE_EXT 0x322C
#define EGL_DRM_DEVICE_FILE_EXT 0x3233
#define EGL_DRM_RENDER_NODE_FILE_EXT 0x3234
#define EGL_EXTENSIONS 0x302D

static void *g_mali;
static void *g_hook;
static void *(*g_mali_gpa)(const char *);
static pthread_once_t g_once = PTHREAD_ONCE_INIT;

static void ensure_once_body(void) {
  /* The stock libEGL dispatcher loads libmali-hook.so.1 (which intercepts
   * eglGetDisplay/eglGetPlatformDisplay/... and dispatches per display type)
   * alongside the raw blob.  Mirror that chain exactly and resolve forwarders
   * through the hook first, falling back to the blob. */
  g_hook = dlopen("libmali-hook.so.1", RTLD_NOW | RTLD_GLOBAL | RTLD_NODELETE);
  g_mali = dlopen("libmali.so.1", RTLD_NOW | RTLD_GLOBAL | RTLD_NODELETE);
  if (g_mali) g_mali_gpa = (void *(*)(const char *))dlsym(g_mali, "eglGetProcAddress");
}
static void ensure_init(void) { pthread_once(&g_once, ensure_once_body); }
#define ensure() ensure_init()

/* hook -> blob -> GPA resolution, mirroring the stock dispatch order */
static void *resolve_real(const char *name) {
  if (g_hook) {
    void *p = dlsym(g_hook, name);
    if (p) return p;
  }
  if (g_mali) {
    void *p = dlsym(g_mali, name);
    if (p) return p;
  }
  return g_mali_gpa ? g_mali_gpa(name) : NULL;
}

/* ---- shim implementations of the missing EGL_EXT_device_query surface ---- */

/* The device libmali really uses for allocation/render is the rockchip-drm
 * render node; expose it as the (single) EGL device. */
#define FAKE_DEVICE ((EGLDeviceEXT)(intptr_t)0x1000)

/*
 * The device-query stubs exist for exactly one consumer: Firefox's glxtest.
 * Exposing them to everyone makes mutter enter its multi-GPU device paths
 * (they are written for real EGL_EXT_device_query drivers like Mesa) and it
 * dies on NULL strings, taking the wayland greeter down with it -> gdm falls
 * back to X11.  So gate the stubs on the probing process itself and let every
 * other caller see "supported but false", i.e. the stock blob behaviour.
 */
static pthread_once_t g_exe_once = PTHREAD_ONCE_INIT;
static int g_is_glxtest;
static void detect_exe(void) {
  char buf[256];
  ssize_t n = readlink("/proc/self/exe", buf, sizeof(buf) - 1);
  if (n > 0) {
    buf[n] = '\0';
    g_is_glxtest = strstr(buf, "glxtest") != NULL;
  }
}
static int is_glxtest(void) {
  pthread_once(&g_exe_once, detect_exe);
  return g_is_glxtest;
}

EGLBoolean eglQueryDisplayAttribEXT(EGLDisplay dpy, EGLint name,
                                    EGLAttrib *value) {
  (void)dpy;
  if (name == EGL_DEVICE_EXT && is_glxtest()) {
    if (value) *value = (EGLAttrib)FAKE_DEVICE;
    return EGL_TRUE;
  }
  return EGL_FALSE;
}

const char *eglQueryDeviceStringEXT(EGLDeviceEXT device, EGLint name) {
  if (!is_glxtest() || device != FAKE_DEVICE) return NULL;
  switch (name) {
    case EGL_EXTENSIONS:
      return ""; /* no EGL_MESA_device_software => hardware accelerated */
    case EGL_DRM_DEVICE_FILE_EXT:
    case EGL_DRM_RENDER_NODE_FILE_EXT:
      return "/dev/dri/renderD128";
    default:
      return NULL;
  }
}

EGLBoolean eglQueryDevicesEXT(EGLint max, EGLDeviceEXT *devices, EGLint *num) {
  if (!is_glxtest()) {
    if (num) *num = 0;
    return EGL_TRUE;
  }
  if (num) *num = 1;
  if (max > 0 && devices) devices[0] = FAKE_DEVICE;
  return EGL_TRUE;
}

const char *eglGetDisplayDriverName(EGLDisplay dpy) {
  (void)dpy;
  if (!is_glxtest()) return NULL;
  return "rockchip";
}

const char *eglGetDisplayDriverConfig(EGLDisplay dpy) {
  (void)dpy;
  /* callers (mutter) feed the result to g_str_has_prefix; never return NULL */
  return "";
}

/* forward decls: enhanced impls referenced by shim_gpa_impl below */
EGLBoolean eglChooseConfig(EGLDisplay, const EGLint *, EGLConfig *, EGLint, EGLint *);
EGLContext eglCreateContext(EGLDisplay, EGLConfig, EGLContext, const EGLint *);
EGLDisplay eglGetDisplay(EGLNativeDisplayType);
const char *eglQueryString(EGLDisplay, EGLint);
EGLDisplay eglGetPlatformDisplay(EGLenum, void *, const EGLAttrib *);
EGLDisplay eglGetPlatformDisplayEXT(EGLenum, void *, const EGLint *);
static int dbg(void);
static FILE *dbg_target(void);
static const unsigned char *dbg_glGetString(unsigned name);

static void *shim_gpa_impl(const char *name) {
  if (!name) return NULL;
  if (!strcmp(name, "eglQueryDisplayAttribEXT")) return (void *)eglQueryDisplayAttribEXT;
  if (!strcmp(name, "eglQueryDeviceStringEXT")) return (void *)eglQueryDeviceStringEXT;
  if (!strcmp(name, "eglQueryDevicesEXT")) return (void *)eglQueryDevicesEXT;
  if (!strcmp(name, "eglGetDisplayDriverName")) return (void *)eglGetDisplayDriverName;
  if (!strcmp(name, "eglGetDisplayDriverConfig")) return (void *)eglGetDisplayDriverConfig;
  /* enhanced implementations must also be reachable via eglGetProcAddress,
   * which is how firefox/epoxy resolve several core entry points */
  if (!strcmp(name, "eglChooseConfig")) return (void *)eglChooseConfig;
  if (!strcmp(name, "eglCreateContext")) return (void *)eglCreateContext;
  if (!strcmp(name, "eglGetDisplay")) return (void *)eglGetDisplay;
  if (!strcmp(name, "eglQueryString")) return (void *)eglQueryString;
  if (!strcmp(name, "eglGetPlatformDisplay")) return (void *)eglGetPlatformDisplay;
  if (!strcmp(name, "eglGetPlatformDisplayEXT")) return (void *)eglGetPlatformDisplayEXT;
  /* prefer real blob exports (covers glGetString and all ext entry points) */
  if (!strcmp(name, "glGetString") && dbg()) {
    return (void *)dbg_glGetString;
  }
  return resolve_real(name);
}

static const unsigned char *(*real_glGetString)(unsigned);
const unsigned char *dbg_glGetString(unsigned name) {
  if (!real_glGetString)
    real_glGetString = (const unsigned char *(*)(unsigned))resolve_real("glGetString");
  const unsigned char *r = real_glGetString ? real_glGetString(name) : NULL;
  fprintf(dbg_target(), "Z96A:glGetString(%u) -> \"%s\" (pid %d)\n", name,
          r ? (const char *)r : "(null)", getpid());
  return r;
}

/* eglGetProcAddress: forwards to the blob, injecting the shim symbols. */
void *eglGetProcAddress(const char *name) {
  ensure();
  return shim_gpa_impl(name);
}

/* ---- generic forwarders ---- */
static int dbg(void) {
  static int v = -1;
  if (v < 0) v = getenv("Z96A_EGL_DEBUG") ? 1 : 0;
  return v;
}
/* NEVER print to stderr under glxtest: its stderr IS the result pipe
 * firefox parses; stray output corrupts the gfx info. */
static FILE *dbg_target(void) {
  if (!is_glxtest()) return stderr;
  static FILE *f;
  if (!f) f = fopen("/tmp/z96a-egl-glxtest.log", "a");
  return f;
}

#define FORW(ret, name, params, args)                    \
  static ret (*_fp_##name) params;                       \
  ret name params {                                      \
    ensure();                                            \
    if (!_fp_##name)                                     \
      _fp_##name = (ret(*) params)resolve_real(#name);   \
    if (!_fp_##name) {                                   \
      return (ret)0;                                     \
    }                                                    \
    if (dbg())                                           \
      fprintf(dbg_target(), "Z96A:%s\n", #name);               \
    return _fp_##name args;                              \
  }

static EGLBoolean (*_fp_eglChooseConfig)(EGLDisplay, const EGLint *, EGLConfig *,
                                         EGLint, EGLint *);
static EGLBoolean (*_fp_eglGetConfigs)(EGLDisplay, EGLConfig *, EGLint, EGLint *);
static EGLBoolean (*_fp_eglGetConfigAttrib)(EGLDisplay, EGLConfig, EGLint, EGLint *);

/* Spec-shaped manual config matching: the hook/blob's eglChooseConfig
 * rejects several ordinary attribute sets (EGL_BAD_ATTRIBUTE / 0 configs)
 * which breaks Firefox. When the real call comes back empty, match by hand
 * against the full config list. */
static EGLBoolean manual_choose(EGLDisplay dpy, const EGLint *attrib_list,
                                EGLConfig *configs, EGLint config_size,
                                EGLint *num_config) {
  if (!_fp_eglGetConfigs)
    _fp_eglGetConfigs = (EGLBoolean (*)(EGLDisplay, EGLConfig *, EGLint, EGLint *))resolve_real("eglGetConfigs");
  if (!_fp_eglGetConfigAttrib)
    _fp_eglGetConfigAttrib = (EGLBoolean (*)(EGLDisplay, EGLConfig, EGLint, EGLint *))resolve_real("eglGetConfigAttrib");
  if (!_fp_eglGetConfigs || !_fp_eglGetConfigAttrib) return EGL_FALSE;
  if (dbg()) fprintf(dbg_target(), "Z96A:manual_choose enter\n");

  EGLint total = 0;
  if (_fp_eglGetConfigs(dpy, NULL, 0, &total) != EGL_TRUE || total <= 0)
    return EGL_FALSE;
  EGLConfig *all = calloc(total, sizeof(EGLConfig));
  if (!all) return EGL_FALSE;
  EGLint got = 0;
  EGLBoolean ok = _fp_eglGetConfigs(dpy, all, total, &got);
  if (ok != EGL_TRUE || got <= 0) { free(all); return EGL_FALSE; }

  /* collect the request */
  EGLint keys[32], want[32];
  int nreq = 0;
  for (const EGLint *a = attrib_list; a && a[0] != 0x3053 && nreq < 32; a += 2) {
    keys[nreq] = a[0]; want[nreq] = a[1]; nreq++;
  }

  int matched = 0;
  for (int i = 0; i < got && (configs == NULL || matched < config_size); i++) {
    EGLConfig c = all[i];
    int good = 1;
    for (int k = 0; k < nreq && good; k++) {
      EGLint v = 0;
      if (_fp_eglGetConfigAttrib(dpy, c, keys[k], &v) != EGL_TRUE)
        continue; /* unqueryable key: ignore instead of rejecting */
      switch (keys[k]) {
        case 0x3033: /* EGL_SURFACE_TYPE */
        case 0x3042: /* EGL_CONFORMANT */
          if ((v & want[k]) != want[k]) good = 0;
          break;
        case 0x3040: /* EGL_RENDERABLE_TYPE: the blob reports only the ES2
                       * bit yet happily serves ES3 contexts (glxtest proof);
                       * accept any GLES bit request on ES2-capable configs */
          if (want[k] & 0x0004) { /* OpenGL_ES2_BIT */
            if (!(v & 0x0004)) good = 0;
          } else if (want[k] & 0x0040) { /* OpenGL_ES3_BIT */
            if (!(v & (0x0004 | 0x0040))) good = 0;
          } else if ((v & want[k]) != want[k]) {
            good = 0;
          }
          break;
        case 0x3024: case 0x3023: case 0x3022: /* RGB sizes */
        case 0x3021: /* ALPHA */
        case 0x3025: /* DEPTH */
        case 0x3026: /* STENCIL */
        case 0x3032: /* SAMPLES */
        case 0x3031: /* SAMPLE_BUFFERS */
          if (v < want[k]) good = 0;
          break;
        default: /* caveats, ids, visual types: exact match */
          if (v != want[k]) good = 0;
          break;
      }
    }
    if (good) {
      /* configs==NULL is the spec's "count only" query: never write */
      if (configs) configs[matched] = c;
      matched++;
      if (dbg()) fprintf(dbg_target(), "Z96A:manual_choose hit cfg %d\n", i);
    }
  }
  free(all);
  if (num_config) *num_config = matched;
  return matched > 0 ? EGL_TRUE : EGL_FALSE;
}

EGLBoolean eglChooseConfig(EGLDisplay dpy, const EGLint *attrib_list,
                           EGLConfig *configs, EGLint config_size,
                           EGLint *num_config) {
  /* The hook's eglChooseConfig segfaults on several ordinary attribute
   * lists (e.g. anything carrying EGL_CONFIG_ID) and the blob's own one
   * rejects most sets, so match by hand against the spec and use the raw
   * blob's chooser (never the hook's) only as a last resort. */
  EGLBoolean m = manual_choose(dpy, attrib_list, configs, config_size, num_config);
  if (m == EGL_TRUE) return EGL_TRUE;
  ensure();
  if (!_fp_eglChooseConfig)
    _fp_eglChooseConfig = (EGLBoolean (*)(EGLDisplay, const EGLint *, EGLConfig *,
                                          EGLint, EGLint *))dlsym(g_mali, "eglChooseConfig");
  if (!_fp_eglChooseConfig)
    _fp_eglChooseConfig = (EGLBoolean (*)(EGLDisplay, const EGLint *, EGLConfig *,
                                          EGLint, EGLint *))resolve_real("eglChooseConfig");
  if (!_fp_eglChooseConfig) return 0;
  EGLBoolean r = _fp_eglChooseConfig(dpy, attrib_list, configs, config_size, num_config);
  if (dbg())
    fprintf(dbg_target(), "Z96A:eglChooseConfig native -> r=%d n=%d\n", r,
            num_config ? *num_config : -1);
  if (r == EGL_TRUE && num_config && *num_config > 1) {
    /* Firefox's hardware WebRender creates a pbuffer on configs[0]; the blob
     * hands back window-only configs first and MakeCurrent then fails, so
     * bubble pbuffer-capable configs to the front. */
    static EGLBoolean (*_ga)(EGLDisplay, EGLConfig, EGLint, EGLint *);
    if (!_ga) _ga = (EGLBoolean (*)(EGLDisplay, EGLConfig, EGLint, EGLint *))resolve_real("eglGetConfigAttrib");
    if (_ga) {
      for (int i = 0; i < *num_config; i++) {
        EGLint st = 0;
        if (_ga(dpy, configs[i], 0x3033, &st) != EGL_TRUE) continue;
        if (st & 0x0001) continue; /* already pbuffer-capable */
        for (int j = i + 1; j < *num_config; j++) {
          EGLint st2 = 0;
          if (_ga(dpy, configs[j], 0x3033, &st2) != EGL_TRUE) continue;
          if (st2 & 0x0001) {
            EGLConfig tmp = configs[i];
            configs[i] = configs[j];
            configs[j] = tmp;
            break;
          }
        }
      }
    }
  }
  return r;
}
FORW(EGLBoolean, eglCopyBuffers,
     (EGLDisplay dpy, EGLSurface surface, EGLNativePixmapType pixmap),
     (dpy, surface, pixmap))
static EGLContext (*_fp_eglCreateContext)(EGLDisplay, EGLConfig, EGLContext,
                                          const EGLint *);
EGLContext eglCreateContext(EGLDisplay dpy, EGLConfig config,
                            EGLContext share_context,
                            const EGLint *attrib_list) {
  ensure();
  if (!_fp_eglCreateContext)
    _fp_eglCreateContext = (EGLContext (*)(EGLDisplay, EGLConfig, EGLContext,
                                           const EGLint *))resolve_real("eglCreateContext");
  if (!_fp_eglCreateContext) return NULL;
  EGLContext ctx = _fp_eglCreateContext(dpy, config, share_context, attrib_list);
  if (!ctx && attrib_list && attrib_list[0] != 0x3053) {
    /* Blob quirks: KHR attribs with MAJOR=3 are rejected (EGL_BAD_PARAMETER),
     * but MAJOR=2 yields the full ES3.2 context (glxtest relies on exactly
     * this fallback). The failed attempt also leaves a sticky GL error which
     * Firefox's GLContext::Init treats as fatal, so drain it afterwards. */
    static EGLint es2[] = {0x30FB, 2, 0x3053}; /* EGL_CONTEXT_MAJOR_VERSION_KHR = 2 */
    ctx = _fp_eglCreateContext(dpy, config, share_context, es2);
    if (dbg())
      fprintf(dbg_target(), "Z96A:eglCreateContext retry-es2 -> %p (pid %d)\n", ctx,
              getpid());
    if (ctx) {
      static EGLint (*ge)(void);
      if (!ge) ge = (EGLint (*)(void))resolve_real("eglGetError");
      for (int i = 0; ge && i < 8; i++) {
        EGLint e = ge();
        if (!e) break;
        if (dbg()) fprintf(dbg_target(), "Z96A:drain stale GL err %x\n", e);
      }
    }
  }
  return ctx;
}
static EGLSurface (*_fp_eglCreatePbufferSurface)(EGLDisplay, EGLConfig, const EGLint *);
EGLSurface eglCreatePbufferSurface(EGLDisplay dpy, EGLConfig config,
                                   const EGLint *attrib_list) {
  ensure();
  if (!_fp_eglCreatePbufferSurface)
    _fp_eglCreatePbufferSurface = (EGLSurface (*)(EGLDisplay, EGLConfig, const EGLint *))resolve_real("eglCreatePbufferSurface");
  if (!_fp_eglCreatePbufferSurface) return NULL;
  EGLSurface s = _fp_eglCreatePbufferSurface(dpy, config, attrib_list);
  if (dbg()) {
    static EGLint (*ge)(void);
    if (!ge) ge = (EGLint (*)(void))resolve_real("eglGetError");
    fprintf(dbg_target(), "Z96A:eglCreatePbufferSurface cfg=%p -> %p err=%x\n",
            config, s, ge ? (unsigned)ge() : 0);
  }
  return s;
}
FORW(EGLSurface, eglCreatePixmapSurface,
     (EGLDisplay dpy, EGLConfig config, EGLNativePixmapType pixmap,
      const EGLint *attrib_list),
     (dpy, config, pixmap, attrib_list))
FORW(EGLSurface, eglCreateWindowSurface,
     (EGLDisplay dpy, EGLConfig config, EGLNativeWindowType win,
      const EGLint *attrib_list),
     (dpy, config, win, attrib_list))
FORW(EGLBoolean, eglDestroyContext, (EGLDisplay dpy, EGLContext ctx),
     (dpy, ctx))
FORW(EGLBoolean, eglDestroySurface, (EGLDisplay dpy, EGLSurface surface),
     (dpy, surface))
FORW(EGLBoolean, eglGetConfigAttrib,
     (EGLDisplay dpy, EGLConfig config, EGLint attribute, EGLint *value),
     (dpy, config, attribute, value))
FORW(EGLBoolean, eglGetConfigs,
     (EGLDisplay dpy, EGLConfig *configs, EGLint config_size, EGLint *num_config),
     (dpy, configs, config_size, num_config))
FORW(EGLDisplay, eglGetCurrentDisplay, (void), ())
FORW(EGLSurface, eglGetCurrentSurface, (EGLint readdraw), (readdraw))
static EGLDisplay (*_fp_eglGetDisplay)(EGLNativeDisplayType);
EGLDisplay eglGetDisplay(EGLNativeDisplayType native_display) {
  ensure();
  if (!_fp_eglGetDisplay)
    _fp_eglGetDisplay = (EGLDisplay (*)(EGLNativeDisplayType))resolve_real("eglGetDisplay");
  if (!_fp_eglGetDisplay) return NULL;
  EGLDisplay d = _fp_eglGetDisplay(native_display);
  if (dbg())
    fprintf(dbg_target(), "Z96A:eglGetDisplay native=%p -> dpy=%p pid=%d\n",
            native_display, d, getpid());
  return d;
}
FORW(EGLint, eglGetError, (void), ())
FORW(EGLBoolean, eglInitialize,
     (EGLDisplay dpy, EGLint *major, EGLint *minor), (dpy, major, minor))
static EGLBoolean (*_fp_eglMakeCurrent)(EGLDisplay, EGLSurface, EGLSurface, EGLContext);
EGLBoolean eglMakeCurrent(EGLDisplay dpy, EGLSurface draw, EGLSurface read,
                          EGLContext ctx) {
  ensure();
  if (!_fp_eglMakeCurrent)
    _fp_eglMakeCurrent = (EGLBoolean (*)(EGLDisplay, EGLSurface, EGLSurface, EGLContext))resolve_real("eglMakeCurrent");
  if (!_fp_eglMakeCurrent) return 0;
  EGLBoolean r = _fp_eglMakeCurrent(dpy, draw, read, ctx);
  if (dbg()) {
    static EGLint (*ge)(void);
    if (!ge) ge = (EGLint (*)(void))resolve_real("eglGetError");
    fprintf(dbg_target(), "Z96A:eglMakeCurrent draw=%p read=%p ctx=%p -> %d err=%x\n",
            draw, read, ctx, r, ge ? (unsigned)ge() : 0);
  }
  return r;
}
FORW(EGLBoolean, eglQueryContext,
     (EGLDisplay dpy, EGLContext ctx, EGLint attribute, EGLint *value),
     (dpy, ctx, attribute, value))
/*
 * libmali bug workaround: the blob compiles its extension strings in but
 * eglQueryString(dpy, EGL_EXTENSIONS) returns an empty string through the
 * gbm/wayland dispatch paths, which makes clients (Firefox) conclude that
 * EGL_KHR_surfaceless_context / EGL_EXT_image_dma_buf_import are missing.
 * Fall back to the blob's own native strings when the forwarded query is
 * empty.
 */
static const char Z96A_MALI_DISPLAY_EXTS[] =
    "EGL_KHR_config_attribs EGL_KHR_image EGL_KHR_image_base "
    "EGL_KHR_fence_sync EGL_KHR_wait_sync EGL_KHR_gl_colorspace "
    "EGL_KHR_get_all_proc_addresses EGL_IMG_context_priority "
    "EGL_KHR_no_config_context EGL_EXT_image_dma_buf_import "
    "EGL_EXT_image_dma_buf_import_modifiers EGL_EXT_yuv_surface "
    "EGL_EXT_pixel_format_float EGL_ARM_pixmap_multisample_discard "
    "EGL_ANDROID_native_fence_sync EGL_KHR_gl_texture_2D_image "
    "EGL_KHR_gl_texture_3D_image EGL_KHR_gl_renderbuffer_image "
    "EGL_KHR_create_context EGL_KHR_surfaceless_context "
    "EGL_KHR_gl_texture_cubemap_image EGL_EXT_image_gl_colorspace "
    "EGL_EXT_create_context_robustness";
static const char Z96A_MALI_CLIENT_EXTS[] =
    "EGL_EXT_client_extensions EGL_EXT_platform_base "
    "EGL_KHR_client_get_all_proc_addresses EGL_KHR_platform_gbm "
    "EGL_KHR_platform_wayland EGL_EXT_platform_wayland";

static const char *(*_fp_eglQueryString)(EGLDisplay, EGLint);
const char *eglQueryString(EGLDisplay dpy, EGLint name) {
  ensure();
  if (!_fp_eglQueryString)
    _fp_eglQueryString = (const char *(*)(EGLDisplay, EGLint))dlsym(g_mali, "eglQueryString");
  if (!_fp_eglQueryString) return NULL;
  const char *r = _fp_eglQueryString(dpy, name);
  if (!r || !*r) {
    if (name == EGL_EXTENSIONS) {
      if (dpy == NULL)
        return Z96A_MALI_CLIENT_EXTS;
      return Z96A_MALI_DISPLAY_EXTS;
    }
    /* The hook path also returns NULL for these; callers (mutter/cogl)
     * feed them straight into g_str_has_prefix etc. and abort on NULL. */
    if (dpy != NULL) {
      if (name == 0x3053) return "ARM";               /* EGL_VENDOR */
      if (name == 0x3054) return "1.5 Z96A-mali-wrapper"; /* EGL_VERSION */
      if (name == 0x308D) return "OpenGL_ES ";        /* EGL_CLIENT_APIS */
    }
  }
  return r;
}
FORW(EGLBoolean, eglQuerySurface,
     (EGLDisplay dpy, EGLSurface surface, EGLint attribute, EGLint *value),
     (dpy, surface, attribute, value))
FORW(EGLBoolean, eglReleaseThread, (void), ())
/* frame/资源计数器: 判决"计数型 bug vs 时间型 bug" */
static unsigned long g_swap_count;
static unsigned long g_img_create, g_img_destroy;
static void bump_log(const char *what, unsigned long n) {
  if (dbg() && (n % 25 == 0))
    fprintf(dbg_target(), "Z96A:counter %s #%lu (pid %d)\n", what, n, getpid());
}
EGLBoolean eglSwapBuffers(EGLDisplay dpy, EGLSurface surface) {
  ensure();
  static EGLBoolean (*fp)(EGLDisplay, EGLSurface);
  if (!fp) fp = (EGLBoolean (*)(EGLDisplay, EGLSurface))resolve_real("eglSwapBuffers");
  if (!fp) return 0;
  bump_log("swap", ++g_swap_count);
  return fp(dpy, surface);
}
EGLImage eglCreateImageKHR(EGLDisplay dpy, EGLContext ctx, EGLenum target,
                           void *buffer, const EGLint *attrib_list) {
  ensure();
  static EGLImage (*fp)(EGLDisplay, EGLContext, EGLenum, void *, const EGLint *);
  if (!fp) fp = (EGLImage (*)(EGLDisplay, EGLContext, EGLenum, void *, const EGLint *))resolve_real("eglCreateImageKHR");
  if (!fp) return NULL;
  EGLImage r = fp(dpy, ctx, target, buffer, attrib_list);
  bump_log("img_create", ++g_img_create);
  return r;
}
EGLBoolean eglDestroyImageKHR(EGLDisplay dpy, EGLImage image) {
  ensure();
  static EGLBoolean (*fp)(EGLDisplay, EGLImage);
  if (!fp) fp = (EGLBoolean (*)(EGLDisplay, EGLImage))resolve_real("eglDestroyImageKHR");
  if (!fp) return 0;
  EGLBoolean r = fp(dpy, image);
  bump_log("img_destroy", ++g_img_destroy);
  return r;
}
FORW(EGLBoolean, eglSwapInterval, (EGLDisplay dpy, EGLint interval),
     (dpy, interval))
FORW(EGLBoolean, eglTerminate, (EGLDisplay dpy), (dpy))
FORW(EGLBoolean, eglWaitGL, (void), ())
FORW(EGLBoolean, eglWaitNative, (EGLint engine), (engine))
FORW(EGLBoolean, eglBindAPI, (EGLenum api), (api))
FORW(EGLenum, eglQueryAPI, (void), ())
FORW(EGLSurface, eglCreatePbufferFromClientBuffer,
     (EGLDisplay dpy, EGLenum buftype, void *buffer, EGLConfig config,
      const EGLint *attrib_list),
     (dpy, buftype, buffer, config, attrib_list))
FORW(EGLBoolean, eglReleaseTexImage,
     (EGLDisplay dpy, EGLSurface surface, EGLint buffer),
     (dpy, surface, buffer))
FORW(EGLBoolean, eglSurfaceAttrib,
     (EGLDisplay dpy, EGLSurface surface, EGLint attribute, EGLint value),
     (dpy, surface, attribute, value))
/* The blob's eglGetPlatformDisplay returns NULL for EGL_PLATFORM_WAYLAND,
 * which is what GTK4 uses. eglGetDisplay(wl_display) works fine, and for
 * the blob they are equivalent - so reroute. */
static EGLDisplay (*_fp_eglGetPlatformDisplay)(EGLenum, void *, const EGLAttrib *);
EGLDisplay eglGetPlatformDisplay(EGLenum platform, void *native_display,
                                 const EGLAttrib *attrib_list) {
  ensure();
  if (!_fp_eglGetPlatformDisplay)
    _fp_eglGetPlatformDisplay = (EGLDisplay (*)(EGLenum, void *, const EGLAttrib *))resolve_real("eglGetPlatformDisplay");
  if (platform == 0x31E8 /* EGL_PLATFORM_WAYLAND_KHR */ && native_display) {
    if (!_fp_eglGetDisplay)
      _fp_eglGetDisplay = (EGLDisplay (*)(EGLNativeDisplayType))resolve_real("eglGetDisplay");
    if (_fp_eglGetDisplay) {
      EGLDisplay d = _fp_eglGetDisplay(native_display);
      if (dbg()) fprintf(dbg_target(), "Z96A:eglGetPlatformDisplay(WAYLAND) reroute -> %p\n", d);
      return d;
    }
  }
  if (!_fp_eglGetPlatformDisplay) return NULL;
  return _fp_eglGetPlatformDisplay(platform, native_display, attrib_list);
}
static EGLDisplay (*_fp_eglGetPlatformDisplayEXT)(EGLenum, void *, const EGLint *);
EGLDisplay eglGetPlatformDisplayEXT(EGLenum platform, void *native_display,
                                    const EGLint *attrib_list) {
  ensure();
  if (!_fp_eglGetPlatformDisplayEXT)
    _fp_eglGetPlatformDisplayEXT = (EGLDisplay (*)(EGLenum, void *, const EGLint *))resolve_real("eglGetPlatformDisplayEXT");
  if (platform == 0x31E8 /* EGL_PLATFORM_WAYLAND_KHR */ && native_display) {
    if (!_fp_eglGetDisplay)
      _fp_eglGetDisplay = (EGLDisplay (*)(EGLNativeDisplayType))resolve_real("eglGetDisplay");
    if (_fp_eglGetDisplay) {
      EGLDisplay d = _fp_eglGetDisplay(native_display);
      if (dbg()) fprintf(dbg_target(), "Z96A:eglGetPlatformDisplayEXT(WAYLAND) reroute -> %p\n", d);
      return d;
    }
  }
  if (!_fp_eglGetPlatformDisplayEXT) return NULL;
  return _fp_eglGetPlatformDisplayEXT(platform, native_display, attrib_list);
}
FORW(EGLSurface, eglCreatePlatformWindowSurface,
     (EGLDisplay dpy, EGLConfig config, void *native_window,
      const EGLint *attrib_list),
     (dpy, config, native_window, attrib_list))
FORW(EGLSurface, eglCreatePlatformPixmapSurface,
     (EGLDisplay dpy, EGLConfig config, void *native_pixmap,
      const EGLint *attrib_list),
     (dpy, config, native_pixmap, attrib_list))
FORW(EGLSync, eglCreateSync,
     (EGLDisplay dpy, EGLenum type, const EGLAttrib *attrib_list),
     (dpy, type, attrib_list))
FORW(EGLBoolean, eglDestroySync, (EGLDisplay dpy, EGLSync sync), (dpy, sync))
FORW(EGLint, eglClientWaitSync,
     (EGLDisplay dpy, EGLSync sync, EGLint flags, EGLTime timeout),
     (dpy, sync, flags, timeout))
FORW(EGLBoolean, eglGetSyncAttrib,
     (EGLDisplay dpy, EGLSync sync, EGLint attribute, EGLAttrib *value),
     (dpy, sync, attribute, value))
FORW(EGLSync, eglWaitSync,
     (EGLDisplay dpy, EGLenum mode, const EGLint *attrib_list),
     (dpy, mode, attrib_list))
FORW(EGLImage, eglCreateImage,
     (EGLDisplay dpy, EGLContext ctx, EGLenum target, void *buffer,
      const EGLint *attrib_list),
     (dpy, ctx, target, buffer, attrib_list))
FORW(EGLBoolean, eglDestroyImage, (EGLDisplay dpy, EGLImage image),
     (dpy, image))
FORW(EGLSync, eglCreateSyncKHR,
     (EGLDisplay dpy, EGLenum type, const EGLint *attrib_list),
     (dpy, type, attrib_list))
FORW(EGLBoolean, eglDestroySyncKHR, (EGLDisplay dpy, EGLSync sync), (dpy, sync))
FORW(EGLint, eglClientWaitSyncKHR,
     (EGLDisplay dpy, EGLSync sync, EGLint flags, EGLTime timeout),
     (dpy, sync, flags, timeout))
FORW(EGLBoolean, eglGetSyncAttribKHR,
     (EGLDisplay dpy, EGLSync sync, EGLint attribute, EGLint *value),
     (dpy, sync, attribute, value))
FORW(EGLSync, eglWaitSyncKHR,
     (EGLDisplay dpy, EGLenum mode, const EGLint *attrib_list),
     (dpy, mode, attrib_list))
/* eglCreateImageKHR/eglDestroyImageKHR have counter-instrumented impls above */
