# From https://github.com/Java-Techie-jt/docker-jenkins-integration-sample
# this is invalid as dockerfile will not build because jar file is missing

FROM openjdk:8
EXPOSE 8080
ADD target/docker-jenkins-integration-sample.jar docker-jenkins-integration-sample.jar
ENTRYPOINT ["java","-jar","/docker-jenkins-integration-sample.jar"]