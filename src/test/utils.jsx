import React from 'react'
import { render } from '@testing-library/react'
import { MemoryRouter, Route, Routes } from 'react-router-dom'

// Render `element` at `path` inside a router. Extra routes let tests assert on
// redirects (e.g. { '/login': <div>login page</div> }).
export function renderAt(element, { path = '/', extraRoutes = {} } = {}) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <Routes>
        <Route path={path.split('?')[0]} element={element} />
        {Object.entries(extraRoutes).map(([p, el]) => <Route key={p} path={p} element={el} />)}
      </Routes>
    </MemoryRouter>,
  )
}
