# Workers = processos (paralelismo de CPU); threads = concorrência de I/O por processo.
# Ajuste WEB_CONCURRENCY para o nº de CPUs do container.
workers Integer(ENV.fetch("WEB_CONCURRENCY", 2))
max_threads = Integer(ENV.fetch("RAILS_MAX_THREADS", 16))
threads max_threads, max_threads

port ENV.fetch("PORT", 3000)
environment ENV.fetch("RAILS_ENV", "production")

preload_app!
