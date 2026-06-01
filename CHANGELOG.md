# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Oblique pseudo-3D (2.5D) city rendering from real OpenStreetMap geometry
- Buildings extruded from real heights, depth-sorted, lit, backface-culled
- Heading-up camera with rotation and sprint
- Driveable vehicles (cars and bikes) via interact system
- Near-plane polygon clipping (Sutherland-Hodgman)
- CI/CD pipeline with rolling `latest-main` releases and GitHub Pages deploy
- Project website with play-in-browser and download links
- Shared framework submodule (`src/love2d4me/`) — input, projection, polygon, vehicle, interactable
- `npm run setup` bootstraps a dev machine (installs deps + downloads LOVE 11.5)
- `npm start` launches the game, `npm run dev` uses local submodule working copy
- love.js web build (WASM) — play in the browser
- Headless screenshot mode (`love src play shot`) for CI validation
