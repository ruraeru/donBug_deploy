# 빌드 컨텍스트: donBug_BE
FROM eclipse-temurin:17-jdk AS build
WORKDIR /src
COPY . .
# application-secret.yml 은 gitignore 대상. 템플릿(${ENV:기본값})을 넣고 실제 값은 컨테이너 환경변수로 준다.
RUN cp src/main/resources/application-secret.sample.yml src/main/resources/application-secret.yml \
 && bash ./gradlew bootJar -x test --no-daemon \
 && cp build/libs/*-SNAPSHOT.jar /app.jar

FROM eclipse-temurin:17-jre
ENV TZ=Asia/Seoul
COPY --from=build /app.jar /app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app.jar"]
