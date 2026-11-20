/*
 * pw-camera-filter — hide camera formats that Chromium would display corrupted.
 *
 * Problem: Chromium's PipeWire camera capture (--enable-features=WebRtcPipeWireCamera)
 * assumes tightly packed rows and ignores the buffer stride. Apple Silicon's camera
 * driver (apple-isp, Asahi Linux) pads every row to a 64-byte boundary, so all modes
 * whose width isn't a multiple of 64 (480x640, 720x1280, 1080x1920, 1328x1760, ...)
 * come out sheared. Chromium picks those modes for small requests (e.g. Slack's
 * camera preview negotiates 480x640).
 *
 * Fix: this library is installed as /app/lib/libpipewire-0.3.so.0, which Chromium
 * dlopen()s ahead of the runtime's libpipewire. It links to the real library
 * (via the libpipewire-0.3-real.so.0 symlink), so every symbol resolves to the real
 * implementation, except pw_proxy_add_object_listener. libpipewire's protocol
 * module calls that when Chromium adds a node listener. For apple-isp camera nodes
 * we wrap the listener and drop EnumFormat params whose width isn't 64-aligned, so
 * Chromium only ever sees (and requests) tightly packed modes.
 *
 * Disable at runtime with SLACK_PW_CAMERA_FILTER=0.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <pipewire/pipewire.h>
#include <spa/param/format.h>
#include <spa/pod/iter.h>
#include <spa/pod/parser.h>

typedef void (*add_object_listener_fn)(struct pw_proxy *, struct spa_hook *, const void *, void *);
typedef const char *(*get_type_fn)(struct pw_proxy *, uint32_t *);

static add_object_listener_fn real_add_object_listener;
static get_type_fn real_get_type;
static bool enabled = true;

struct node_wrap {
	const struct pw_node_events *orig;
	void *orig_data;
	struct pw_node_events events;
	bool padded_driver;   /* node is a camera whose driver pads rows to 64 bytes */
};

static void resolve(void)
{
	if (real_add_object_listener)
		return;
	void *real = dlopen("libpipewire-0.3-real.so.0", RTLD_NOW | RTLD_NOLOAD);
	if (!real)
		real = dlopen("libpipewire-0.3-real.so.0", RTLD_NOW);
	if (!real) {
		fprintf(stderr, "pw-camera-filter: cannot open real libpipewire: %s\n", dlerror());
		abort();
	}
	real_add_object_listener = (add_object_listener_fn)dlsym(real, "pw_proxy_add_object_listener");
	real_get_type = (get_type_fn)dlsym(real, "pw_proxy_get_type");
	const char *env = getenv("SLACK_PW_CAMERA_FILTER");
	enabled = !(env && strcmp(env, "0") == 0);
}

static bool driver_pads_rows(const struct spa_dict *props)
{
	const char *drv = props ? spa_dict_lookup(props, "api.v4l2.cap.driver") : NULL;
	return drv && strcmp(drv, "apple-isp") == 0;
}

static void wrap_info(void *data, const struct pw_node_info *info)
{
	struct node_wrap *w = data;
	if (info && (info->change_mask & PW_NODE_CHANGE_MASK_PROPS) && driver_pads_rows(info->props))
		w->padded_driver = true;
	if (w->orig->info)
		w->orig->info(w->orig_data, info);
}

static void wrap_param(void *data, int seq, uint32_t id, uint32_t index, uint32_t next,
		       const struct spa_pod *param)
{
	struct node_wrap *w = data;
	if (w->padded_driver && id == SPA_PARAM_EnumFormat && param) {
		const struct spa_pod_prop *p = spa_pod_find_prop(param, NULL, SPA_FORMAT_VIDEO_size);
		struct spa_rectangle size;
		if (p && spa_pod_get_rectangle(&p->value, &size) == 0 && size.width % 64 != 0)
			return;   /* padded mode: Chromium would ignore the stride */
	}
	if (w->orig->param)
		w->orig->param(w->orig_data, seq, id, index, next, param);
}

SPA_EXPORT
void pw_proxy_add_object_listener(struct pw_proxy *proxy, struct spa_hook *listener,
				  const void *funcs, void *data)
{
	resolve();
	const char *type = (enabled && real_get_type) ? real_get_type(proxy, NULL) : NULL;
	const struct pw_node_events *ev = funcs;
	if (!type || strcmp(type, PW_TYPE_INTERFACE_Node) != 0 || !ev) {
		real_add_object_listener(proxy, listener, funcs, data);
		return;
	}
	struct node_wrap *w = calloc(1, sizeof(*w));   /* lives as long as the node proxy */
	if (!w) {
		real_add_object_listener(proxy, listener, funcs, data);
		return;
	}
	w->orig = ev;
	w->orig_data = data;
	w->events.version = PW_VERSION_NODE_EVENTS;
	w->events.info = wrap_info;
	w->events.param = wrap_param;
	real_add_object_listener(proxy, listener, &w->events, w);
}
