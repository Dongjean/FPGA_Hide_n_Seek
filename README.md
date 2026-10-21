# FPGA_Hide_n_Seek

A Wolfenstein-style First-Person Shooter Hide and Seek game with 2 Basys3 boards

## Contributors

- Dongjin Shin
- Toh Jian Bin
- Andrew Chong Kian Wei
- Isaac Goh Yong Chee

## Tech Stack
- Verilog

## Repository Structure

Since this repository tracks the Vivado project file directly, the key directories and files are organized as follows:

- `*.xpr` — The main Vivado project file.
- `src/` — Verilog/SystemVerilog source files.
- `constraints/` — Pin mapping and timing constraints (`.xdc`).
- `.gitignore` — Excludes build artifacts, caches, runs, and temporary logs.

## Setup

### Prerequisites
- [Software] **Xilinx/AMD Vivado Design Suite** (tested on version [Insert Version, e.g., 2023.1])
- [Hardware] Target hardware board (e.g., **Digilent Basys 3 Artix-7 FPGA**)

### Cloning and Opening the Project

1. Clone the repository

2. Open the project on Vivado
  - Open Vivado, run Hide_n_Seek.xpr
  - Write the bitstream to create all the other initialization files

## Git Feature Branch Workflow

1. **Pull latest changes from GitHub**
    ```bash
    git checkout main
    git pull origin main
    ```

2. **Create new feature branch locally**
    ```bash
    git checkout -b feature/name-of-feature
    ```

3. **Make the first changes and commit**
    ```bash
    git add .
    git commit -m "commit name"
    ```

4. **Push changes to GitHub and set upstream with -u**
    ```bash
    git push -u origin feature/name-of-feature
    ```

5. **Open a Pull Request on GitHub and resolve any Merge Conflicts**

6. **Delete the feature branch on GitHub (after merging)**

7. **Delete the feature branch on the local repository**
    ```bash
    git checkout main
    git pull origin main
    git branch -d feature/name-of-feature
    ```

8. **Delete the remote branch on the local repository**
    ```bash
    git fetch --prune
    ```
    * This removes local remote branches that no longer exist on github