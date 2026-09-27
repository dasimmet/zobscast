#pragma once

#include <media-io/audio-io.h>
#include <media-io/video-io.h>
#include <obs-config.h>
#include <obs-data.h>
#include <obs-defs.h>
#include <obs-interaction.h>
#include <obs-properties.h>
#include <util/base.h>
#include <util/bmem.h>
#include <util/c99defs.h>
#include <util/platform.h>
#include <util/text-lookup.h>

struct obs_output;
typedef struct obs_output obs_output_t;
struct obs_source;
typedef struct obs_source obs_source_t;
struct obs_scene;
typedef struct obs_scene obs_scene_t;
struct obs_module;
typedef struct obs_module obs_module_t;
struct obs_encoder;
typedef struct obs_encoder obs_encoder_t;
struct obs_service;
typedef struct obs_service obs_service_t;
struct obs_canvas;
typedef struct obs_canvas obs_canvas_t;
struct obs_video_info;
struct obs_sceneitem;
typedef struct obs_sceneitem obs_sceneitem_t;

#include <obs-encoder.h>
#include <obs-output.h>

EXPORT obs_output_t *obs_output_create(const char *id, const char *name,
                                       obs_data_t *settings,
                                       obs_data_t *hotkey_data);
EXPORT bool obs_output_start(obs_output_t *output);
EXPORT void obs_output_set_video_encoder(obs_output_t *output,
                                         obs_encoder_t *encoder);
EXPORT bool obs_output_can_begin_data_capture(const obs_output_t *output,
                                              uint32_t flags);
EXPORT bool obs_output_initialize_encoders(obs_output_t *output,
                                           uint32_t flags);
EXPORT bool obs_output_begin_data_capture(obs_output_t *output, uint32_t flags);
EXPORT void obs_output_end_data_capture(obs_output_t *output);
EXPORT void obs_output_signal_stop(obs_output_t *output, int code);
EXPORT obs_output_t *obs_get_output_by_name(const char *name);
EXPORT void obs_output_stop(obs_output_t *output);
EXPORT bool obs_output_active(const obs_output_t *output);
EXPORT void obs_output_release(obs_output_t *output);
EXPORT void obs_output_update(obs_output_t *output, obs_data_t *settings);
EXPORT obs_data_t *obs_output_get_settings(const obs_output_t *output);
EXPORT uint32_t obs_output_get_width(const obs_output_t *output);
EXPORT uint32_t obs_output_get_height(const obs_output_t *output);
EXPORT obs_encoder_t *obs_output_get_video_encoder(const obs_output_t *output);

EXPORT video_t *obs_get_video(void);
EXPORT obs_encoder_t *obs_video_encoder_create(const char *id, const char *name,
                                               obs_data_t *settings,
                                               obs_data_t *hotkey_data);
EXPORT void obs_encoder_set_preferred_video_format(obs_encoder_t *encoder,
                                                   enum video_format format);
EXPORT void obs_encoder_set_video(obs_encoder_t *encoder, video_t *video);
EXPORT void obs_encoder_release(obs_encoder_t *encoder);
EXPORT bool obs_encoder_get_extra_data(const obs_encoder_t *encoder,
                                       uint8_t **extra_data, size_t *size);

EXPORT obs_source_t *obs_source_create_private(const char *id, const char *name,
                                               obs_data_t *settings);
EXPORT void obs_source_release(obs_source_t *source);
EXPORT void obs_canvas_release(obs_canvas_t *canvas);
EXPORT char *obs_module_get_config_path(obs_module_t *module, const char *file);
EXPORT lookup_t *obs_module_load_locale(obs_module_t *module,
                                        const char *default_locale,
                                        const char *locale);

#include <obs-frontend-api.h>

/* Source types & registration from obs-source.h */
enum obs_source_type {
  OBS_SOURCE_TYPE_INPUT,
  OBS_SOURCE_TYPE_FILTER,
  OBS_SOURCE_TYPE_TRANSITION,
  OBS_SOURCE_TYPE_SCENE,
};

#define OBS_SOURCE_VIDEO (1 << 0)
#define OBS_SOURCE_AUDIO (1 << 1)

struct obs_source_info {
  const char *id;
  enum obs_source_type type;
  uint32_t output_flags;
  const char *(*get_name)(void *type_data);
  void *(*create)(obs_data_t *settings, obs_source_t *source);
  void (*destroy)(void *data);
  uint32_t (*get_width)(void *data);
  uint32_t (*get_height)(void *data);
  void (*get_defaults)(obs_data_t *settings);
  obs_properties_t *(*get_properties)(void *data);
  void (*update)(void *data, obs_data_t *settings);
  void (*activate)(void *data);
  void (*deactivate)(void *data);
  void (*show)(void *data);
  void (*hide)(void *data);
  void (*video_tick)(void *data, float seconds);
  void (*video_render)(void *data, void *effect);
  struct obs_source_frame *(*filter_video)(void *data,
                                           struct obs_source_frame *frame);
  struct obs_audio_data *(*filter_audio)(void *data,
                                         struct obs_audio_data *audio);
  void (*enum_active_sources)(void *data,
                              void (*enum_callback)(obs_source_t *,
                                                    obs_source_t *, void *),
                              void *param);
  void (*save)(void *data, obs_data_t *settings);
  void (*load)(void *data, obs_data_t *settings);
  void (*mouse_click)(void *data, const struct obs_mouse_event *event,
                      int32_t type, bool mouse_up, uint32_t click_count);
  void (*mouse_move)(void *data, const struct obs_mouse_event *event,
                     bool mouse_leave);
  void (*mouse_wheel)(void *data, const struct obs_mouse_event *event,
                      int x_delta, int y_delta);
  void (*focus)(void *data, bool focus);
  void (*key_click)(void *data, const struct obs_key_event *event, bool key_up);
  void (*filter_remove)(void *data, obs_source_t *source);
  void *type_data;
  void (*free_type_data)(void *type_data);
  bool (*audio_render)(void *data, uint64_t *ts_out,
                       struct obs_source_audio_mix *audio_output,
                       uint32_t mixers, size_t channels, size_t sample_rate);
  void (*enum_all_sources)(void *data,
                           void (*enum_callback)(obs_source_t *, obs_source_t *,
                                                 void *),
                           void *param);
  void (*transition_start)(void *data);
  void (*transition_stop)(void *data);
  void (*get_defaults2)(void *type_data, obs_data_t *settings);
  obs_properties_t *(*get_properties2)(void *data, void *type_data);
  bool (*audio_mix)(void *data, uint64_t *ts_out, void *audio_output,
                    size_t channels, size_t sample_rate);
  uint32_t icon_type;
  void (*media_play_pause)(void *data, bool pause);
  void (*media_restart)(void *data);
  void (*media_stop)(void *data);
  void (*media_next)(void *data);
  void (*media_previous)(void *data);
  int64_t (*media_get_duration)(void *data);
  int64_t (*media_get_time)(void *data);
  void (*media_set_time)(void *data, int64_t miliseconds);
  int (*media_get_state)(void *data);
  uint32_t version;
  const char *unversioned_id;
  void *(*missing_files)(void *data);
  int (*video_get_color_space)(void *data, size_t count,
                               const void *preferred_spaces);
  void (*filter_add)(void *data, obs_source_t *source);
};

EXPORT void obs_register_source_s(const struct obs_source_info *info,
                                  size_t size);
#define obs_register_source(info)                                              \
  obs_register_source_s(info, sizeof(struct obs_source_info))

/* POSIX network & timing for discovery */
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
