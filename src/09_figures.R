# src/09_figures.R  (figures in R with ggplot2)
# Figure 1: cold-start curve, pooled WAPE by k for the main models (test set).
# Figure 2: 80% interval coverage before and after conformal recalibration (test set).
# Run from the project root: Rscript src/09_figures.R
suppressPackageStartupMessages({ library(data.table); library(ggplot2) })
dir.create("figures", showWarnings = FALSE)

pooled <- fread("results/B_cold_start_metrics_pooled_h1to4.csv")
# M4 is omitted at k = 8, 12, 16, 20 (failed fits, README 5.1): those rows have blank WAPE in the CSV
p1 <- pooled[model %in% c("M0", "M1", "M2", "M3", "M4", "M5", "M5g") & !is.na(wape)]
p1[, model := factor(model, levels = c("M0", "M1", "M2", "M3", "M4", "M5", "M5g"),
                     labels = c("M0 carry-forward", "M1 own mean", "M2 own series NB", "M3 global NB",
                                "M4 partial pooling (EB)", "M5 analog-only", "M5g global average curve"))]
g1 <- ggplot(p1, aes(k, wape, colour = model, group = model)) +
  geom_line(linewidth = 0.8) + geom_point(size = 1.8) +
  scale_x_continuous(breaks = c(1, 2, 3, 4, 6, 8, 12, 16, 20, 26)) +
  labs(title = "Cold-start curve: WAPE pooled over 1 to 4 weeks ahead (test launches)",
       subtitle = "Lower is better. M4 has no point at k = 8, 12, 16, 20: those fits failed (README 5.1).",
       x = "Weeks of own history (k)", y = "WAPE", colour = NULL) +
  theme_minimal(base_size = 11) + theme(legend.position = "bottom")
ggsave("figures/fig1_cold_start_wape.png", g1, width = 8, height = 5.2, dpi = 150)

cal <- fread("results/E_calibration_before_after_conformal.csv")
c2 <- cal[nominal == 0.8 & model %in% c("M0", "M3", "M4") & !is.na(test_coverage_raw)]
c2l <- melt(c2, id.vars = c("model", "k"), measure.vars = c("test_coverage_raw", "test_coverage_conformal"),
            variable.name = "version", value.name = "coverage")
c2l[, version := ifelse(version == "test_coverage_raw", "before recalibration", "after conformal")]
g2 <- ggplot(c2l, aes(k, coverage, colour = model, linetype = version, group = interaction(model, version))) +
  geom_hline(yintercept = 0.8, colour = "grey40") +
  geom_hline(yintercept = c(0.72, 0.88), colour = "grey70", linetype = "dotted") +
  geom_line() + geom_point(size = 1.6) +
  scale_x_continuous(breaks = c(1, 2, 3, 4, 6, 8, 12, 16, 20, 26)) +
  labs(title = "80% interval coverage on test launches",
       subtitle = "Grey solid line = nominal 0.80. Dotted = 0.72 and 0.88 (F4). M4 omitted at k = 8, 12, 16, 20 (failed fits).",
       x = "Weeks of own history (k)", y = "Observed coverage", colour = NULL, linetype = NULL) +
  theme_minimal(base_size = 11) + theme(legend.position = "bottom")
ggsave("figures/fig2_interval_coverage.png", g2, width = 8, height = 5.2, dpi = 150)
cat("figures written\n")
