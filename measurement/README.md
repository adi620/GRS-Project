# Measurement

This directory contains scripts used to measure application-level behavior during the experiments. These scripts collect metrics such as request latency and traffic activity while the system is running.

## Flow of the Measurement

1. Start the Kubernetes workload and traffic generator.
2. Run the measurement scripts to capture application-level metrics.
3. Execute fault injection or experiment scripts.
4. Record how the application metrics change during the experiment.
5. Use the collected measurements to compare baseline and fault conditions.
