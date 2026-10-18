FROM ruby:3.4-slim
WORKDIR /opt/appstore-release-notes
COPY lib/ ./lib/
COPY bin/ ./bin/
RUN chmod 755 bin/appstore-release-notes && ln -s /opt/appstore-release-notes/bin/appstore-release-notes /usr/local/bin/appstore-release-notes
USER 65532:65532
CMD ["appstore-release-notes", "--help"]
