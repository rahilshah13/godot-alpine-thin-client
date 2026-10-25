#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <time.h>
#include <math.h>
#include <pthread.h>
#include <unistd.h>
#include <sys/stat.h>

#include <wlr/util/log.h>
#include <wlr/types/wlr_output.h>
#include "types.h"

#define SHARED_DIR "/data/local/tmp/shared_bundle"

// Forward declaration of send_frame
void send_frame(struct server *s);

static void write_ppm_frame(uint32_t *pixels, int width, int height, uint32_t frame_id) {
    // Ensure shared directory exists
    struct stat st = {0};
    if (stat(SHARED_DIR, &st) == -1) {
        mkdir(SHARED_DIR, 0777);
    }

    char filepath[512];
    snprintf(filepath, sizeof(filepath), "%s/frame_%06u.ppm", SHARED_DIR, frame_id);

    char tmp_filepath[512];
    snprintf(tmp_filepath, sizeof(tmp_filepath), "%s.tmp", filepath);

    FILE *f = fopen(tmp_filepath, "wb");
    if (!f) return;

    fprintf(f, "P6\n%d %d\n255\n", width, height);
    for (int i = 0; i < width * height; i++) {
        uint32_t p = pixels[i];
        uint8_t b = (p >> 0) & 0xFF;
        uint8_t g = (p >> 8) & 0xFF;
        uint8_t r = (p >> 16) & 0xFF;
        fputc(r, f);
        fputc(g, f);
        fputc(b, f);
    }
    fclose(f);

    // Atomic rename to prevent partial reads by Flutter
    rename(tmp_filepath, filepath);
}

void send_frame(struct server *s) {
    pthread_mutex_lock(&s->send_lock);
    
    if (s->resize_pending) {
        pthread_mutex_unlock(&s->send_lock);
        return;
    }

    int buf = -1;
    for (int i = 0; i < 2; i++) {
        if (i != s->active_buf && i != s->pending_buf) {
            buf = i;
            break;
        }
    }
    
    if (buf < 0) {
        pthread_mutex_unlock(&s->send_lock);
        return;
    }
    
    uint32_t *tmp     = s->send_buf[buf];
    s->send_buf[buf]  = s->framebuf;
    s->framebuf       = tmp;

    s->pending_buf = buf;
    if (s->force_full_frame) s->send_full = 1;
    pthread_cond_signal(&s->send_cond);
    pthread_mutex_unlock(&s->send_lock);
}

int send_timer_callback(void *data) {
    struct server *s = data;
    if (!s->frame_dirty) return 0;
    s->frame_dirty = 0;
    send_frame(s);
    return 0;
}

void *send_thread_func(void *arg) {
    struct server *s = arg;
    wlr_log(WLR_INFO, "Filesystem Frame-Streaming Thread Started (VirtioFS)");

    uint32_t frame_id = 0;

    while (s->running) {
        pthread_mutex_lock(&s->send_lock);
        while (s->pending_buf < 0 && !s->window_changed && s->running) {
            pthread_cond_wait(&s->send_cond, &s->send_lock);
        }
        pthread_mutex_unlock(&s->send_lock);
        if (!s->running) break;

        pthread_mutex_lock(&s->send_lock);
        int current_buf = s->pending_buf;
        int got_frame = (current_buf >= 0);
        if (got_frame) {
            s->active_buf = current_buf;
            s->pending_buf = -1;
        }
        pthread_mutex_unlock(&s->send_lock);
        
        uint32_t *send_buf = got_frame ? s->send_buf[current_buf] : NULL;
        
        if (send_buf) {
            if (s->visible_width < s->width || s->visible_height < s->height) {
                if (s->visible_width < s->width) {
                    int pad = s->width - s->visible_width;
                    for (int y = 0; y < s->visible_height; y++)
                        memset(&send_buf[y * s->width + s->visible_width], 0,
                               pad * sizeof(uint32_t));
                }
                if (s->visible_height < s->height) {
                    memset(&send_buf[s->visible_height * s->width], 0,
                           (s->height - s->visible_height) * s->width
                           * sizeof(uint32_t));
                }
            }

            // Write frame to shared VirtioFS directory as P6 PPM
            write_ppm_frame(send_buf, s->width, s->height, frame_id++);
        }

        if (got_frame) {
            pthread_mutex_lock(&s->send_lock);
            s->active_buf = -1;
            pthread_mutex_unlock(&s->send_lock);
        }
    }
    
    wlr_log(WLR_INFO, "Filesystem Frame-Streaming Thread Exiting");
    return NULL;
}