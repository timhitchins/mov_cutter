# Simple Movie Cutter

A small command-line app that cuts one long video into named clips using a CSV of start/end times, then optionally converts those clips to MP4. It is a thin, well-behaved wrapper around `ffmpeg`.

```
mov_cutter/
├── cutter.sh        the app
├── README.md       this file
├── source/         put the long .mov here
├── metadata/       put the cuts .csv here
└── cuts/
    ├── mov/        clips written by "cut"
    └── mp4/        files written by "convert" (or "cut --to mp4")
```

The app finds its folders relative to itself, so you can run it from any directory and the layout always stays the same.

## Requirements

- Ubuntu (or any Linux/macOS with bash 4+)
- `ffmpeg` (includes `ffprobe`) and `awk`

```bash
sudo apt update
sudo apt install -y ffmpeg
ffmpeg -version | head -1
```

It was tested with ffmpeg 6.1. It only uses long-standing ffmpeg options, so the 4.4 version that ships with Ubuntu 22.04 should work too.

## Quick start

```bash
# 1. Go to the app folder and make the script executable (one time)
cd ~/Documents/mov_cutter
chmod +x cutter.sh

# 2. Create the folders (safe to repeat)
./cutter.sh init

# 3. Put your video in source/. A symlink avoids copying a huge file:
ln -s "$HOME/Documents/project_burlesque/2026-10-18-witch - 18 October 2026 - 06-47-23 PM.mov" source/
#    (or move/copy it:  mv "<path to file>" source/ )

# 4. Put your CSV in metadata/
cp ~/Downloads/pb_mov_cuts.csv metadata/

# 5. Check the CSV against the video without cutting anything
./cutter.sh check

# 6. Cut the clips and convert them to MP4
./cutter.sh all
```

Results appear in `cuts/mov/` and `cuts/mp4/`.

## The CSV file

Three columns: `start`, `end`, `name`. The header row is optional.

```csv
start,end,name
15:15,29:12,intro
29:15,33:24,burn_your_village
1:04:02,1:09:35,my_cat
```

Time formats accepted:

| You write   | Meaning                                  |
| ----------- | ---------------------------------------- |
| `90`        | 90 seconds                               |
| `15:15`     | 15 minutes 15 seconds (**MM:SS**)        |
| `1:04:02`   | 1 hour 4 minutes 2 seconds (**H:MM:SS**) |
| `1:04:02.5` | decimals are allowed on the seconds      |

Rules:

- `name` becomes the filename (`intro` gives `intro.mov` / `intro.mp4`). Names cannot contain `/`, cannot start with `.`, and must be unique.
- Blank lines and lines starting with `#` are ignored.
- Windows line endings and a missing newline on the last row are handled.
- A bad row (end before start, past the end of the video, invalid time, duplicate name) is reported and skipped. The good rows still run, and the script exits with an error code at the end so you notice.

## Commands

| Command   | What it does                                                                             |
| --------- | ---------------------------------------------------------------------------------------- |
| `init`    | Creates the folder layout                                                                |
| `check`   | Validates the CSV against the source video and prints a table of every cut. Cuts nothing |
| `cut`     | Cuts clips into `cuts/mov/` (or `cuts/mp4/` with `--to mp4`)                             |
| `convert` | Converts every clip in `cuts/mov/` to MP4 in `cuts/mp4/`                                 |
| `all`     | `cut` (to .mov), then `convert`                                                          |
| `status`  | Shows how many files and how much space each folder uses                                 |

## Options

| Option             | Applies to              | What it does                                                                                   |
| ------------------ | ----------------------- | ---------------------------------------------------------------------------------------------- |
| `-i, --input FILE` | check, cut, all         | Source video. A bare filename is looked up in `source/`. Default: the only `.mov` in `source/` |
| `-c, --csv FILE`   | check, cut, all         | Cuts CSV. A bare filename is looked up in `metadata/`. Default: the only `.csv` in `metadata/` |
| `--to mov\|mp4`    | cut                     | Write clips as `.mov` (default) or straight to `.mp4`                                          |
| `--fast`           | cut                     | Copy streams without re-encoding. Instant, but cuts can be a second or two off                 |
| `-m, --mp4-mode`   | convert, all            | `auto` (default), `copy`, or `encode`                                                          |
| `--crf N`          | convert, all            | Re-encode quality, lower is better (default 20)                                                |
| `-f, --force`      | all commands that write | Overwrite existing files (default: skip them)                                                  |
| `-n, --dry-run`    | all commands that write | Print the ffmpeg commands without running them                                                 |
| `-h, --help`       |                         | Show help                                                                                      |

If `source/` or `metadata/` holds more than one matching file, the app lists them and asks you to choose with `-i` or `-c`.

## Common workflows

**Full run with exact cuts (recommended).** Cuts are re-encoded so they start exactly on your timestamps, then MP4s are made.

```bash
./cutter.sh check
./cutter.sh all
```

**Quick rough cuts.** Stream copy is nearly instant and lossless, but each cut snaps to the nearest earlier keyframe, so clips can start a second or two early.

```bash
./cutter.sh cut --fast
```

**Skip the .mov step, go straight to MP4.**

```bash
./cutter.sh cut --to mp4
```

**Convert existing clips only.**

```bash
./cutter.sh convert
```

**Re-do the MP4s at higher quality.** `-f` overwrites the existing MP4s.

```bash
./cutter.sh convert -m encode --crf 18 -f
```

**Use a specific video or CSV** when you have several.

```bash
./cutter.sh all -i "show_night2.mov" -c night2_cuts.csv
```

**Preview before running.**

```bash
./cutter.sh all -n
```

**Fix one cut and redo only that clip.** Edit the CSV, delete the old clip, and run again. Existing files are skipped, so only the missing one is made.

```bash
rm cuts/mov/intro.mov cuts/mp4/intro.mp4
./cutter.sh all
```

## How it works

- **Accurate cuts (default).** `cut` seeks to the start time and re-encodes that section to H.264 video and AAC audio (CRF 18), so the clip begins and ends on your exact timestamps.
- **Fast cuts (`--fast`).** The streams are copied as is. This is lossless and instant, but video can only start on a keyframe.
- **Converting to MP4 (`auto`).** If a clip is already H.264 video with AAC audio, the app only changes the container (no quality loss, takes seconds). Otherwise it re-encodes. MP4 files include `faststart` so they begin playing right away when streamed or uploaded.
- **Safe writes.** Each clip is written to a `.part` file and renamed only when ffmpeg finishes, so an interrupted run never leaves a half-finished clip that looks complete.
- **Your source is never modified.** The app only reads from `source/`.

## Tips

- **Disk space.** Accurate cuts re-encode, and the `.mov` and `.mp4` copies together can use roughly twice the size of your clips. Check free space with `df -h ~`. If you only need MP4s, use `cut --to mp4`.
- **Time.** Re-encoding a long recording takes a while, so run `check` first to catch mistakes before the slow step.
- **Check a clip's length.**

  ```bash
  ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 cuts/mov/intro.mov
  ```

## Troubleshooting

| Problem                                            | Fix                                                                                                                          |
| -------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `Permission denied` when running `./cutter.sh`     | `chmod +x cutter.sh`, or run `bash cutter.sh ...`                                                                            |
| `'ffmpeg' not found`                               | `sudo apt install ffmpeg`                                                                                                    |
| `no .mov file in .../source`                       | Put the video in `source/` (or pass `-i path/to/file`)                                                                       |
| `several .csv files ... choose one`                | Pass `-c yourfile.csv`                                                                                                       |
| `end ... is past the end of the source`            | A timestamp is longer than the video. Run `check` and fix that row. Also confirm times are `MM:SS` or `H:MM:SS`, not `HH:MM` |
| `end is not after start`                           | Swap or correct the times in that row                                                                                        |
| Clip starts a second early or shows a frozen frame | You used `--fast`. Re-run without it (and with `-f`) for exact cuts                                                          |
| `convert` fails with a codec error in `copy` mode  | Use `-m encode` (or leave the default `auto`)                                                                                |
| Script finished but exit code is 1                 | At least one row or clip failed. Scroll up for the message                                                                   |
| File names with spaces                             | Quote them: `-i "my video.mov"`                                                                                              |

## Cleaning up

Remove generated files and keep the app:

```bash
rm -f cuts/mov/*.mov cuts/mp4/*.mp4
```

Your source video and CSV are untouched by this.
