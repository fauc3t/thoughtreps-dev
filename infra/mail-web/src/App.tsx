import { Component, lazy, Suspense, type ReactNode } from 'react';
import { Outlet, Route, Routes } from 'react-router-dom';
import RequireAuth from './components/RequireAuth';

// One chunk per route component.
const AddressList = lazy(() => import('./pages/AddressList'));
const Inbox = lazy(() => import('./pages/Inbox'));
const Login = lazy(() => import('./pages/Login'));
const Message = lazy(() => import('./pages/Message'));

class RouteErrorBoundary extends Component<
  { children: ReactNode },
  { hasError: boolean }
> {
  state = { hasError: false };

  static getDerivedStateFromError() {
    return { hasError: true };
  }

  render() {
    if (this.state.hasError) {
      return (
        <div className="p-8 text-center">
          <p>Something went wrong — reload</p>
          <button onClick={() => window.location.reload()}>Reload</button>
        </div>
      );
    }
    return this.props.children;
  }
}

export default function App() {
  return (
    <RouteErrorBoundary>
      <Suspense
        fallback={
          <div role="status" aria-live="polite" className="p-8 text-center">
            Loading…
          </div>
        }
      >
        <Routes>
          <Route path="/login" element={<Login />} />
          {/* Pathless layout route: every route below requires a session,
              redirecting to /login if there isn't one (RequireAuth), and
              hands that session down via context for the S3-backed query
              hooks to consume. */}
          <Route
            element={
              <RequireAuth>
                <Outlet />
              </RequireAuth>
            }
          >
            <Route path="/" element={<AddressList />} />
            <Route path="/:address" element={<Inbox />} />
            <Route path="/:address/:key" element={<Message />} />
          </Route>
        </Routes>
      </Suspense>
    </RouteErrorBoundary>
  );
}
