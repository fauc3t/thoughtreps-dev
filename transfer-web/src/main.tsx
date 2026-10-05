import { createRoot } from 'react-dom/client';
import { App } from './App';
import { parseLink } from './lib/link';
import './index.css';

createRoot(document.getElementById('root')!).render(
  <App link={parseLink(location.pathname, location.hash)} />,
);
