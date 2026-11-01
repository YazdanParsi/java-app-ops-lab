# Stage 1: build the WAR with Maven (so the host does not need Java or Maven)
FROM docker.io/library/maven:3.9-eclipse-temurin-21 AS build
WORKDIR /src
COPY pom.xml .
RUN mvn -B -q dependency:go-offline
COPY src ./src
RUN mvn -B -q package

# Stage 2: WildFly with our configuration and the app
FROM quay.io/wildfly/wildfly:latest-jdk21
COPY config.cli /tmp/config.cli
RUN /opt/jboss/wildfly/bin/jboss-cli.sh --file=/tmp/config.cli \
 && rm -rf /opt/jboss/wildfly/standalone/configuration/standalone_xml_history/current
COPY --from=build /src/target/app.war /opt/jboss/wildfly/standalone/deployments/app.war
EXPOSE 8080
