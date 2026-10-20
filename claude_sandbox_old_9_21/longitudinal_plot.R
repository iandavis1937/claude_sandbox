library(ggplot2)
library(dplyr)

set.seed(42)

# Simulated longitudinal data: 30 subjects, 2 groups, 6 visits
n_subj <- 30
visits <- 0:5
df <- expand.grid(id = 1:n_subj, time = visits) |>
  mutate(
    group = ifelse(id <= n_subj / 2, "Control", "Treatment"),
    slope = ifelse(group == "Control", 0.5, 1.5)
  ) |>
  group_by(id) |>
  mutate(intercept = rnorm(1, 10, 2)) |>
  ungroup() |>
  mutate(outcome = intercept + slope * time + rnorm(n(), 0, 1))

group_means <- df |>
  group_by(group, time) |>
  summarise(mean = mean(outcome), se = sd(outcome) / sqrt(n()), .groups = "drop")

p <- ggplot(df, aes(time, outcome, color = group)) +
  geom_line(aes(group = id), alpha = 0.25, linewidth = 0.4) +
  geom_ribbon(data = group_means,
              aes(x = time, ymin = mean - 1.96 * se, ymax = mean + 1.96 * se, fill = group),
              inherit.aes = FALSE, alpha = 0.2) +
  geom_line(data = group_means, aes(y = mean), linewidth = 1.2) +
  geom_point(data = group_means, aes(y = mean), size = 2) +
  scale_x_continuous(breaks = visits) +
  scale_color_manual(values = c(Control = "#1f77b4", Treatment = "#d62728")) +
  scale_fill_manual(values = c(Control = "#1f77b4", Treatment = "#d62728")) +
  labs(title = "Outcome Trajectories Over Time",
       subtitle = "Thin lines: individual subjects; bold lines: group mean ± 95% CI",
       x = "Visit", y = "Outcome", color = "Group", fill = "Group") +
  theme_minimal(base_size = 13) +
  theme(legend.position = "top")

ggsave("longitudinal_plot.png", p, width = 8, height = 5.5, dpi = 150)
p
