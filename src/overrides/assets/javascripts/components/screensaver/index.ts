/*
 * Copyright (c) 2016-2025 Martin Donath <martin.donath@squidfunk.com>
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to
 * deal in the Software without restriction, including without limitation the
 * rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
 * sell copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NON-INFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
 * IN THE SOFTWARE.
 */

import {
  EMPTY,
  Observable,
  animationFrameScheduler,
  fromEvent,
  interval,
  merge,
  of
} from "rxjs"

import {
  distinctUntilChanged,
  filter,
  map,
  mapTo,
  startWith,
  switchMap,
  takeUntil,
  tap
} from "rxjs/operators"

import { Component } from "../_"

/* ----------------------------------------------------------------------------
 * Types
 * ------------------------------------------------------------------------- */

/**
 * Matrix screensaver state
 */
export interface Screensaver {
  active: boolean
}

/* ----------------------------------------------------------------------------
 * Constants
 * ------------------------------------------------------------------------- */

const IDLE_TIMEOUT = 120_000 // 2 minutes of inactivity
const FONT_SIZE = 16
const FADE_ALPHA = 0.05

const MATRIX_CHARS =
  "アイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモ" +
  "ヤユヨラリルレロワヲンABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

/* ----------------------------------------------------------------------------
 * Functions
 * ------------------------------------------------------------------------- */

/**
 * Mount the Matrix screensaver on a container element.
 *
 * Creates a fullscreen canvas overlay that renders falling green characters
 * after a period of user inactivity. Any user input dismisses it.
 *
 * @param el - Screensaver container element
 * @returns Component observable
 */
export function mountScreensaver(
  el: HTMLElement
): Observable<Component<Screensaver>> {

  /* Create canvas element */
  const canvas = document.createElement("canvas")
  const ctx = canvas.getContext("2d")!
  el.appendChild(canvas)

  /* Column drop positions */
  let drops: number[] = []

  /* Resize canvas to fill viewport */
  function resize(): void {
    canvas.width = window.innerWidth
    canvas.height = window.innerHeight
    const columns = Math.floor(canvas.width / FONT_SIZE)
    drops = Array.from({ length: columns }, () =>
      Math.floor(Math.random() * -canvas.height / FONT_SIZE)
    )
  }

  /* Draw a single animation frame */
  function draw(): void {
    ctx.fillStyle = `rgba(0, 0, 0, ${FADE_ALPHA})`
    ctx.fillRect(0, 0, canvas.width, canvas.height)
    ctx.font = `${FONT_SIZE}px monospace`

    for (let i = 0; i < drops.length; i++) {
      const char = MATRIX_CHARS[Math.floor(Math.random() * MATRIX_CHARS.length)]
      const x = i * FONT_SIZE
      const y = drops[i] * FONT_SIZE

      /* Head character is bright white-green, trail is green */
      ctx.fillStyle = Math.random() > 0.95 ? "#fff" : "#0f0"
      ctx.fillText(char, x, y)

      /* Reset drop when it falls off screen (with randomness) */
      if (y > canvas.height && Math.random() > 0.975) {
        drops[i] = 0
      }
      drops[i]++
    }
  }

  /* Stream of user activity events */
  const activity$ = merge(
    fromEvent(document, "mousemove"),
    fromEvent(document, "mousedown"),
    fromEvent(document, "keydown"),
    fromEvent(document, "touchstart"),
    fromEvent(document, "scroll")
  )

  /* Idle state: true after IDLE_TIMEOUT ms of no activity */
  const idle$: Observable<boolean> = activity$.pipe(
    startWith(undefined),
    switchMap(() =>
      merge(
        of(false),
        of(true).pipe(
          switchMap(() => new Observable<boolean>(subscriber => {
            const timer = setTimeout(() => {
              subscriber.next(true)
              subscriber.complete()
            }, IDLE_TIMEOUT)
            return () => clearTimeout(timer)
          }))
        )
      )
    ),
    distinctUntilChanged()
  )

  /* Mount screensaver based on idle state */
  return idle$.pipe(
    switchMap(active => {
      if (!active)
        return of<Component<Screensaver>>({ ref: el, active: false })

      /* Activate: resize, clear canvas, start animation */
      resize()
      ctx.fillStyle = "#000"
      ctx.fillRect(0, 0, canvas.width, canvas.height)
      el.classList.add("mdx-screensaver--active")

      const resize$ = fromEvent(window, "resize").pipe(
        tap(() => resize())
      )

      /* Animation loop at ~60fps */
      const animation$ = interval(0, animationFrameScheduler).pipe(
        tap(() => draw())
      )

      /* Dismiss on any user input */
      const dismiss$ = activity$.pipe(
        tap(() => el.classList.remove("mdx-screensaver--active"))
      )

      return merge(resize$, animation$).pipe(
        takeUntil(dismiss$),
        mapTo<Component<Screensaver>>({ ref: el, active: true }),
        startWith<Component<Screensaver>>({ ref: el, active: true })
      )
    })
  )
}
