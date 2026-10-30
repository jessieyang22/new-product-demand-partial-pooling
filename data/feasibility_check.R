# data/feasibility_check.R
#
# FEASIBILITY ESTIMATE, not component A. This rough count checks whether the
# planned launch cohort is large enough (DESIGN.md section 2, F6) before any
# modelling starts. The official launch counts come from
# src/01_clean_and_launches.R, which applies the full rules.
#
# It uses the rules from DESIGN.md section 3 that matter for the count:
#   - product-like StockCode (5 digits, optional letters)
#   - sales lines only (Invoice does not start with C), positive Quantity,
#     Price > 0
#   - Monday-start weeks, week 1 = week starting Mon 30 Nov 2009
#   - burn-in = weeks 1 to 8 with zero primary demand
#   - launch week L = first week >= 9 with at least 1 unit
#   - test launch = L >= 53; usable for k = 12 with 4 target weeks if L + 15 <= last full week
#
# Run from the project root:
#   Rscript data/feasibility_check.R

suppressPackageStartupMessages(library(data.table))

LINES <- file.path("data", "interim", "lines_combined.rds")
OUT   <- file.path("data", "summary", "feasibility_launch_counts.csv")
if (!file.exists(LINES)) stop("Run data/prep_raw.R first.")

W1_START <- as.Date("2009-11-30")
DATA_END <- as.Date("2011-12-09")
BURN_IN_LAST <- 8L
DEV_FIRST <- 9L
TEST_FIRST <- 53L

lines <- readRDS(LINES)
n_lines_all <- nrow(lines)
lines <- lines[grepl("^[0-9]{5}[A-Za-z]*$", StockCode) &
                 !startsWith(Invoice, "C") &
                 !is.na(Quantity) & Quantity > 0 &
                 !is.na(Price) & Price > 0]
n_lines_kept <- nrow(lines)
lines[, week := as.integer(floor(as.numeric(inv_date - W1_START) / 7) + 1L)]

# Last full week: the week must end on or before the last day of data
week_start <- function(w) W1_START + 7L * (w - 1L)
last_full_week <- max(which(sapply(1:200, function(w) week_start(w) + 6 <= DATA_END)))
message("Last full week index: ", last_full_week, " (starts ", week_start(last_full_week), ")")

demand <- lines[, .(units = sum(Quantity)), by = .(StockCode, week)]
prod <- demand[, .(first_week = min(week),
                   burnin_units = sum(units[week <= BURN_IN_LAST])),
               by = StockCode]
n_products <- nrow(prod)

# Launch week: first week after burn-in with positive demand (joined, not looped)
post <- demand[week > BURN_IN_LAST, .(L = min(week)), by = StockCode]
launch <- merge(prod[burnin_units == 0], post, by = "StockCode")
launch <- launch[L >= DEV_FIRST]

counts <- data.table(
  item = c(
    "lines in the combined table (DATA.md, before filters)",
    "sales lines kept by the filter (product-like code, not cancellation, Quantity > 0, Price > 0)",
    "product-like StockCodes with any positive sales in the window",
    "launch candidates: zero primary demand in burn-in weeks 1 to 8 and a sale after",
    "launch candidates with L in weeks 9 to 52 (development launches)",
    "test launches: L >= 53 (before the data-completeness check)",
    "test launches for k = 12 with 4 target weeks observed (L + 15 <= last full week)",
    "test launches for k = 4 with 4 target weeks observed (L + 7 <= last full week)"
  ),
  count = c(
    n_lines_all,
    n_lines_kept,
    n_products,
    nrow(launch),
    sum(launch$L <= 52L),
    sum(launch$L >= TEST_FIRST),
    sum(launch$L >= TEST_FIRST & launch$L + 15L <= last_full_week),
    sum(launch$L >= TEST_FIRST & launch$L + 7L <= last_full_week)
  )
)

message("FEASIBILITY ESTIMATE (not the official component A count)")
print(counts)
fwrite(counts, OUT)
message("Written: ", OUT)
