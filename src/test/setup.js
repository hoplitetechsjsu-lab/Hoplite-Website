import '@testing-library/jest-dom/vitest'
import { afterEach, vi } from 'vitest'
import { cleanup } from '@testing-library/react'

afterEach(() => {
  cleanup()
})

// jsdom gaps that Radix UI primitives (Dialog, Select, ...) rely on.
if (!window.matchMedia) {
  window.matchMedia = vi.fn().mockImplementation((query) => ({
    matches: false,
    media: query,
    onchange: null,
    addListener: vi.fn(),
    removeListener: vi.fn(),
    addEventListener: vi.fn(),
    removeEventListener: vi.fn(),
    dispatchEvent: vi.fn(),
  }))
}

globalThis.ResizeObserver =
  globalThis.ResizeObserver ||
  class {
    observe() {}
    unobserve() {}
    disconnect() {}
  }

Element.prototype.hasPointerCapture = Element.prototype.hasPointerCapture || (() => false)
Element.prototype.setPointerCapture = Element.prototype.setPointerCapture || (() => {})
Element.prototype.releasePointerCapture = Element.prototype.releasePointerCapture || (() => {})
Element.prototype.scrollIntoView = Element.prototype.scrollIntoView || (() => {})
window.scrollTo = vi.fn()
