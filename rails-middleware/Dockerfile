FROM ruby:3.3-slim

RUN apt-get update -qq && apt-get install -y --no-install-recommends build-essential libjemalloc2 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
ENV RAILS_ENV=production \
    BUNDLE_WITHOUT=development:test \
    BUNDLE_DEPLOYMENT=0 \
    RUBY_YJIT_ENABLE=1 \
    LD_PRELOAD=libjemalloc.so.2 \
    MALLOC_ARENA_MAX=2

COPY Gemfile Gemfile.lock* ./
RUN bundle install --jobs 4

COPY . .
EXPOSE 3000
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
