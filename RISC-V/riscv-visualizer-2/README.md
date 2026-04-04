
# riscv-visualizer-2

A clean-template interactive architecture visualizer built with **Vite + React + Tailwind CSS v4**.

## Getting Started

```bash
npm install
npm run dev
```

## Structure

- `src/App.jsx` — All stages, SVG components, and wires. Edit here to build your diagram.
- `src/index.css` — Global styles (Tailwind import).
- `vite.config.js` / `postcss.config.js` / `tailwind.config.js` — Build tooling configs.

## How It Works

1. Define stages in the `STAGES` array — each stage has `activePaths` listing which wire IDs light up.
2. Add `<Block />` and `<Wire />` SVG helper components inside the `<svg>` element.
3. Pass `active={isActive('path_id')}` to each `<Wire />` to animate it when its stage is active.
