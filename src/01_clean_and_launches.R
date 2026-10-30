# src/01_clean_and_launches.R  (component A)
# Applies DESIGN.md section 3 rules, finds launches, and writes the cohort used by every other component.
# Run from the project root: Rscript src/01_clean_and_launches.R
source("src/lib_pipeline.R")
suppressPackageStartupMessages(library(data.table))
dir.create("results", showWarnings = FALSE)
dir.create("data/interim", showWarnings = FALSE, recursive = TRUE)

cfg <- CFG_DEFAULT
ctx <- prepare_context(cfg)
print(ctx$counts)
fwrite(ctx$counts, "results/A_cleaning_and_launch_counts.csv")

L <- ctx$launch$L
cohort <- data.table(pid = ctx$launch$pid, StockCode = ctx$launch$StockCode, launch_week = L,
                     launch_week_start = as.character(week_start_date(L)), launch_quarter = ctx$launch$qtr,
                     split = ifelse(L <= cfg$dev_last, "dev", "test"))
fwrite(cohort, "results/A_launch_cohort.csv")

# Counts of usable launches per k (training cutoff for dev, full window for test)
cnt <- rbindlist(lapply(K_GRID, function(k) {
  dev_ok <- sum(L >= cfg$dev_first & L <= cfg$dev_last & L + k + H_MAX - 1L <= cfg$dev_last)
  test_ok <- sum(L >= cfg$test_first & L + k + H_MAX - 1L <= LAST_WEEK)
  test_ok_k_only <- sum(L >= cfg$test_first & L + k + H_MAX - 1L <= LAST_WEEK)
  data.table(k = k, dev_launches_usable = dev_ok, test_launches_usable = test_ok_k_only,
             dev_launches_with_L_in_9_52 = sum(L <= cfg$dev_last))
}))
print(cnt)
fwrite(cnt, "results/A_usable_launches_by_k.csv")
cat("Dev launches (L in 9..52):", sum(L <= cfg$dev_last), "\n")
cat("Test launches (L >= 53):", sum(L >= cfg$test_first), "\n")
cat("Distinct descriptions in vocabulary:", length(unique(na.omit(as.vector(ctx$DESC_IDX)))), "\n")
cat("Products dropped by top-1 percent rule in this run:", length(ctx$drop_codes), "\n")
