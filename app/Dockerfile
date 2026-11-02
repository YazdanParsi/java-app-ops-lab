# Stage 1: build the WAR with Maven (so the host does not need Java or Maven).
# --platform=$BUILDPLATFORM runs this stage natively: Java bytecode is the same on every CPU,
# so a cross-build (e.g. amd64 for AKS from an ARM Mac) needs no emulation here.
FROM --platform=$BUILDPLATFORM docker.io/library/maven:3.9-eclipse-temurin-21 AS build
WORKDIR /src
COPY pom.xml .
RUN mvn -B -q dependency:go-offline
COPY src ./src
RUN mvn -B -q package

# Stage 2: apply the WildFly configuration with jboss-cli, also natively (standalone.xml is plain XML)
FROM --platform=$BUILDPLATFORM quay.io/wildfly/wildfly:latest-jdk21 AS config
COPY config.cli /tmp/config.cli
RUN /opt/jboss/wildfly/bin/jboss-cli.sh --file=/tmp/config.cli \
 && rm -rf /opt/jboss/wildfly/standalone/configuration/standalone_xml_history/current

# Stage 3: runtime image for the target platform - only COPY, no RUN, so nothing is emulated
FROM quay.io/wildfly/wildfly:latest-jdk21
COPY --from=config --chown=jboss:0 /opt/jboss/wildfly/standalone/configuration/standalone.xml /opt/jboss/wildfly/standalone/configuration/standalone.xml
COPY --from=build /src/target/app.war /opt/jboss/wildfly/standalone/deployments/app.war
EXPOSE 8080
