import React from 'react';
import { createRoot } from 'react-dom/client';
import App from './App.jsx';

const style = document.createElement('style');
style.textContent = `
  * { box-sizing: border-box; }
  html, body, #root { margin: 0; padding: 0; height: 100%; }
  body { background: #0b1120; }
  button { font-family: inherit; }
  ::-webkit-scrollbar { width: 10px; height: 10px; }
  ::-webkit-scrollbar-track { background: transparent; }
  ::-webkit-scrollbar-thumb { background: #1f3252; border-radius: 6px; }
  ::-webkit-scrollbar-thumb:hover { background: #2c4570; }
`;
document.head.appendChild(style);

createRoot(document.getElementById('root')).render(<App />);
