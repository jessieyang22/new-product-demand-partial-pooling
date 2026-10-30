# src/00_config.R
# Fixed settings for the pipeline (DESIGN.md sections 3 to 5).
# Anything here that changes a number must be changed in git before the test
# evaluation, and the change must be recorded in DESIGN.md with a dated note.

CFG_DEFAULT <- list(
  seed        = 20261029L,   # DESIGN.md section 5, item 8
  burn_last   = 8L,          # burn-in = weeks 1 to 8 (rule 6)
  launch_min  = 1,           # launch = first week with >= 1 unit (rule 7)
  dev_first   = 9L,          # development launches: L in 9..52
  dev_last    = 52L,
  test_first  = 53L,         # test launches: L >= 53
  K           = 40L,         # analog count; chosen on development launches only (results/C_dev_K_selection.csv)
  w_text      = 1,           # analog similarity weights: fixed a priori, not tuned
  w_price     = 0.5,
  w_quarter   = 0.25,
  netted      = FALSE,       # robustness: returns netted against demand
  uk_only     = FALSE,       # robustness: United Kingdom customers only
  drop_top1   = FALSE,       # robustness: drop top 1% of products by dev-period volume
  family      = "nb",        # "nb" or "poisson" (robustness)
  split       = "time"       # "time" (primary) or "random" (leaky warning check)
)

# Robustness grid, run at k = 4 only (DESIGN.md section 4, component F)
CFG_VARIANTS <- list(
  baseline      = list(),
  burn13        = list(burn_last = 13L),
  launch5       = list(launch_min = 5),
  netted        = list(netted = TRUE),
  uk_only       = list(uk_only = TRUE),
  drop_top1pct  = list(drop_top1 = TRUE),
  poisson       = list(family = "poisson"),
  K10           = list(K = 10L),
  K20           = list(K = 20L),
  random_split  = list(split = "random")
)
