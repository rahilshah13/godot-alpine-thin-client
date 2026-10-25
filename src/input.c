/*
 * input.c - Thread-safe input queue management
 */

#define _DEFAULT_SOURCE
#define _POSIX_C_SOURCE 200809L
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <time.h>
#include <errno.h>

#include <wlr/util/log.h>
#include "types.h"

/* ============== Input Queue ============== */

void input_queue_init(struct input_queue *q) {
    wlr_log(WLR_DEBUG, "Entering input_queue_init");
    q->head = q->tail = 0;
    pthread_mutex_init(&q->lock, NULL);
    if (pipe(q->pipe_fd) < 0) {
        wlr_log(WLR_ERROR, "pipe failed: %s", strerror(errno));
        q->pipe_fd[0] = q->pipe_fd[1] = -1;
    }
    fcntl(q->pipe_fd[0], F_SETFL, O_NONBLOCK);
    wlr_log(WLR_DEBUG, "Exiting input_queue_init");
}

void input_queue_push(struct input_queue *q, struct input_event *ev) {
    pthread_mutex_lock(&q->lock);
    int next = (q->tail + 1) % INPUT_QUEUE_SIZE;
    if (next != q->head) {
        q->events[q->tail] = *ev;
        q->tail = next;
        char c = 1;
        if (write(q->pipe_fd[1], &c, 1) < 0) { /* ignore */ }
    } else {
        wlr_log(WLR_INFO, "input_queue_push: queue is full");
    }
    pthread_mutex_unlock(&q->lock);
}

int input_queue_pop(struct input_queue *q, struct input_event *ev) {
    pthread_mutex_lock(&q->lock);
    if (q->head == q->tail) {
        pthread_mutex_unlock(&q->lock);
        return 0;
    }
    *ev = q->events[q->head];
    q->head = (q->head + 1) % INPUT_QUEUE_SIZE;
    pthread_mutex_unlock(&q->lock);
    return 1;
}