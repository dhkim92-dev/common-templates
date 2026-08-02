# Spring Boot Logback template

Copy the three XML files directly into the application's `src/main/resources/` directory.
Spring Boot loads `logback-spring.xml`; its `resource` includes resolve the two appender files from the classpath root.

`logback-spring.xml` reads the values of `logging.level.root`, `logging.level.org.springframework`, and `logging.level.org.hibernate` directly from Spring Boot's configuration. The values in its `defaultValue` attributes are only fallbacks. Therefore, change only `application.yaml` (or its profile-specific configuration) to change the output level; do not edit the Logback XML per environment.

The format includes time, level, thread, `traceId`, `spanId`, logger name, and message. `traceId` and `spanId` read the MDC keys of those names and are rendered as an empty value when unavailable. Micrometer Tracing / Brave instrumentation normally populates these keys; custom code can use `MDC.put("traceId", value)` and `MDC.put("spanId", value)` for the current thread.

`FILE` writes the active log to `${LOG_PATH:-./logs}/application.log` and rolls it daily by default, additionally rotating at 100 MB. The commented `fileNamePattern` variants select hourly or monthly archival periods. Override the directory with `-DLOG_PATH=/var/log/application` (or the equivalent `LOG_PATH` environment variable).

## Filebeat sidecar

Yes. A Spring Boot container can write `application.log` into a shared volume, and a Filebeat sidecar that mounts the same volume can tail the file and continuously forward new lines to Logstash. Mount the volume at the same absolute path in both containers and point Filebeat's `filestream` input at the active file, for example `/var/log/application/application.log`.

Use an `emptyDir` volume for logs that need only live for the lifetime of a Pod. Use a PVC only when retained files are a requirement. Filebeat's registry should also be kept in a writable path (for example an `emptyDir` mounted at `/usr/share/filebeat/data`) so it retains offsets during container restarts. Rolled `*.log.gz` archives should normally be excluded: Filebeat only needs the active `application.log`.

For Kubernetes-wide collection, stdout plus a node-level collector is usually simpler. The sidecar design is appropriate when the application requires file logs or its log files need per-Pod isolation.
