import * as cdk from "aws-cdk-lib";
import { Construct } from "constructs";
import * as dynamodb from "aws-cdk-lib/aws-dynamodb";
import * as lambda from "aws-cdk-lib/aws-lambda";
import * as sources from "aws-cdk-lib/aws-lambda-event-sources";
import * as nodejs from "aws-cdk-lib/aws-lambda-nodejs";
import * as iam from "aws-cdk-lib/aws-iam";
import * as logs from "aws-cdk-lib/aws-logs";
import * as cognito from "aws-cdk-lib/aws-cognito";
import * as apigw from "aws-cdk-lib/aws-apigatewayv2";
import * as integrations from "aws-cdk-lib/aws-apigatewayv2-integrations";
import * as authorizers from "aws-cdk-lib/aws-apigatewayv2-authorizers";
import * as s3 from "aws-cdk-lib/aws-s3";
import * as cloudfront from "aws-cdk-lib/aws-cloudfront";
import * as origins from "aws-cdk-lib/aws-cloudfront-origins";
import * as scheduler from "aws-cdk-lib/aws-scheduler";
import * as secrets from "aws-cdk-lib/aws-secretsmanager";
import * as sqs from "aws-cdk-lib/aws-sqs";
import * as cloudwatch from "aws-cdk-lib/aws-cloudwatch";
import path from "node:path";
export class WorkmateStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: cdk.StackProps) {
    super(scope, id, props);
    const table = new dynamodb.Table(this, "Workspace", {
      partitionKey: { name: "pk", type: dynamodb.AttributeType.STRING },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      encryption: dynamodb.TableEncryption.AWS_MANAGED,
      pointInTimeRecoverySpecification: { pointInTimeRecoveryEnabled: true },
      stream: dynamodb.StreamViewType.NEW_AND_OLD_IMAGES,
      timeToLiveAttribute: "expiresAt",
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });
    const bucket = new s3.Bucket(this, "Website", {
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      encryption: s3.BucketEncryption.S3_MANAGED,
      enforceSSL: true,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });
    const backups = new s3.Bucket(this, "DriveBackups", {
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      encryption: s3.BucketEncryption.S3_MANAGED,
      enforceSSL: true,
      versioned: true,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });
    const headers = new cloudfront.ResponseHeadersPolicy(this, "Headers", {
      securityHeadersBehavior: {
        contentTypeOptions: { override: true },
        strictTransportSecurity: {
          accessControlMaxAge: cdk.Duration.days(365),
          includeSubdomains: true,
          override: true,
        },
        frameOptions: {
          frameOption: cloudfront.HeadersFrameOption.DENY,
          override: true,
        },
        referrerPolicy: {
          referrerPolicy:
            cloudfront.HeadersReferrerPolicy.STRICT_ORIGIN_WHEN_CROSS_ORIGIN,
          override: true,
        },
        contentSecurityPolicy: {
          contentSecurityPolicy:
            "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src 'self' https://fonts.gstatic.com; img-src 'self' data:; connect-src 'self' https://*.execute-api.eu-north-1.amazonaws.com https://cognito-idp.eu-north-1.amazonaws.com; frame-ancestors 'none'; base-uri 'self'; form-action 'self'",
          override: true,
        },
      },
    });
    const distribution = new cloudfront.Distribution(this, "Distribution", {
      defaultRootObject: "index.html",
      defaultBehavior: {
        origin: origins.S3BucketOrigin.withOriginAccessControl(bucket),
        viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
        responseHeadersPolicy: headers,
        cachePolicy: cloudfront.CachePolicy.CACHING_OPTIMIZED,
      },
      additionalBehaviors: {
        "config.json": {
          origin: origins.S3BucketOrigin.withOriginAccessControl(bucket),
          viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.HTTPS_ONLY,
          responseHeadersPolicy: headers,
          cachePolicy: cloudfront.CachePolicy.CACHING_DISABLED,
        },
      },
      errorResponses: [
        {
          httpStatus: 403,
          responseHttpStatus: 200,
          responsePagePath: "/index.html",
          ttl: cdk.Duration.seconds(0),
        },
        {
          httpStatus: 404,
          responseHttpStatus: 200,
          responsePagePath: "/index.html",
          ttl: cdk.Duration.seconds(0),
        },
      ],
      priceClass: cloudfront.PriceClass.PRICE_CLASS_100,
    });
    const pool = new cognito.UserPool(this, "Users", {
      selfSignUpEnabled: false,
      signInAliases: { email: true },
      autoVerify: { email: true },
      passwordPolicy: {
        minLength: 12,
        requireDigits: true,
        requireLowercase: true,
        requireUppercase: true,
        requireSymbols: true,
      },
      accountRecovery: cognito.AccountRecovery.EMAIL_ONLY,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });
    const poolClient = pool.addClient("Web", {
      authFlows: { userPassword: true, userSrp: true },
      preventUserExistenceErrors: true,
      accessTokenValidity: cdk.Duration.hours(8),
      idTokenValidity: cdk.Duration.hours(8),
    });
    const secret = new secrets.Secret(this, "WebhookSecret", {
      generateSecretString: { passwordLength: 48, excludePunctuation: true },
    });
    const deadLetter = new sqs.Queue(this, "Failures", {
      retentionPeriod: cdk.Duration.days(14),
      encryption: sqs.QueueEncryption.SQS_MANAGED,
      enforceSSL: true,
    });
    const env = { TABLE_NAME: table.tableName };
    const make = (
      name: string,
      entry: string,
      handler: string,
      environment: Record<string, string>,
    ) =>
      new nodejs.NodejsFunction(this, name, {
        entry: path.resolve(entry),
        handler,
        runtime: lambda.Runtime.NODEJS_22_X,
        architecture: lambda.Architecture.ARM_64,
        memorySize: 256,
        timeout: cdk.Duration.seconds(name === "Planner" ? 120 : 30),
        environment,
        bundling: { minify: true, sourceMap: true, externalModules: [] },
        logGroup: new logs.LogGroup(this, name + "Logs", {
          retention: logs.RetentionDays.TWO_WEEKS,
        }),
        deadLetterQueue: deadLetter,
        retryAttempts: 2,
      });
    const apiFn = make("Api", "server/lambda.ts", "handler", {
      ...env,
      WEBHOOK_SECRET: secret.secretValue.unsafeUnwrap(),
      BACKUP_BUCKET: backups.bucketName,
    });
    backups.grantPut(apiFn, "workspaces/*");
    const worker = make("Reminder", "server/scheduler.ts", "worker", env);
    for (const fn of [apiFn, worker]) {
      table.grantReadWriteData(fn);
      fn.addToRolePolicy(
        new iam.PolicyStatement({
          actions: ["secretsmanager:GetSecretValue"],
          resources: [
            `arn:${this.partition}:secretsmanager:${this.region}:${this.account}:secret:workmate/bots/*`,
          ],
        }),
      );
    }
    apiFn.addToRolePolicy(
      new iam.PolicyStatement({
        actions: [
          "secretsmanager:CreateSecret",
          "secretsmanager:PutSecretValue",
          "secretsmanager:DeleteSecret",
        ],
        resources: [
          `arn:${this.partition}:secretsmanager:${this.region}:${this.account}:secret:workmate/bots/*`,
        ],
      }),
    );
    const group = new scheduler.CfnScheduleGroup(this, "Schedules", {
      name: "workmate-reminders",
    });
    const schedulerRole = new iam.Role(this, "ScheduleRole", {
      assumedBy: new iam.ServicePrincipal("scheduler.amazonaws.com", {
        conditions: {
          StringEquals: { "aws:SourceAccount": this.account },
          ArnLike: { "aws:SourceArn": group.attrArn },
        },
      }),
    });
    worker.grantInvoke(schedulerRole);
    deadLetter.grantSendMessages(schedulerRole);
    const planner = make("Planner", "server/scheduler.ts", "planner", {
      ...env,
      WORKER_ARN: worker.functionArn,
      SCHEDULER_ROLE_ARN: schedulerRole.roleArn,
      SCHEDULE_GROUP: group.ref,
      DEAD_LETTER_ARN: deadLetter.queueArn,
    });
    planner.addToRolePolicy(
      new iam.PolicyStatement({
        actions: [
          "scheduler:CreateSchedule",
          "scheduler:UpdateSchedule",
          "scheduler:DeleteSchedule",
        ],
        resources: [
          `arn:${this.partition}:scheduler:${this.region}:${this.account}:schedule/${group.ref}/*`,
        ],
      }),
    );
    planner.addToRolePolicy(
      new iam.PolicyStatement({
        actions: ["iam:PassRole"],
        resources: [schedulerRole.roleArn],
        conditions: {
          StringEquals: { "iam:PassedToService": "scheduler.amazonaws.com" },
        },
      }),
    );
    planner.addEventSource(
      new sources.DynamoEventSource(table, {
        startingPosition: lambda.StartingPosition.LATEST,
        batchSize: 5,
        retryAttempts: 3,
        bisectBatchOnError: true,
        reportBatchItemFailures: true,
        onFailure: new sources.SqsDlq(deadLetter),
        filters: [
          lambda.FilterCriteria.filter({
            dynamodb: {
              Keys: { pk: { S: lambda.FilterRule.beginsWith("WORKSPACE#") } },
            },
          }),
        ],
      }),
    );
    const api = new apigw.HttpApi(this, "HttpApi", {
      corsPreflight: {
        allowOrigins: [`https://${distribution.distributionDomainName}`],
        allowMethods: [
          apigw.CorsHttpMethod.GET,
          apigw.CorsHttpMethod.PUT,
          apigw.CorsHttpMethod.POST,
        ],
        allowHeaders: ["authorization", "content-type"],
        maxAge: cdk.Duration.hours(1),
      },
    });
    const integration = new integrations.HttpLambdaIntegration(
      "Handler",
      apiFn,
    );
    const auth = new authorizers.HttpJwtAuthorizer(
      "Auth",
      pool.userPoolProviderUrl,
      { jwtAudience: [poolClient.userPoolClientId] },
    );
    api.addRoutes({
      path: "/api/{proxy+}",
      methods: [
        apigw.HttpMethod.GET,
        apigw.HttpMethod.PUT,
        apigw.HttpMethod.POST,
      ],
      integration,
      authorizer: auth,
    });
    api.addRoutes({ path: "/agent/{proxy+}", methods: [apigw.HttpMethod.GET, apigw.HttpMethod.POST], integration });
    api.addRoutes({
      path: "/device/{proxy+}",
      methods: [apigw.HttpMethod.GET, apigw.HttpMethod.PUT, apigw.HttpMethod.POST],
      integration,
    });
    api.addRoutes({
      path: "/api/telegram/webhook/{bot}",
      methods: [apigw.HttpMethod.POST],
      integration,
    });
    new cloudwatch.Alarm(this, "DeliveryFailures", {
      metric: deadLetter.metricApproximateNumberOfMessagesVisible(),
      threshold: 1,
      evaluationPeriods: 1,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
      alarmDescription:
        "Workmate has failed reminder or schedule events. Inspect the failure queue.",
    });
    const outputs = {
      WebsiteUrl: `https://${distribution.distributionDomainName}`,
      BucketName: bucket.bucketName,
      DistributionId: distribution.distributionId,
      ApiUrl: api.apiEndpoint,
      UserPoolId: pool.userPoolId,
      ClientId: poolClient.userPoolClientId,
      Region: this.region,
      TableName: table.tableName,
      BackupBucketName: backups.bucketName,
    };
    for (const [key, value] of Object.entries(outputs))
      new cdk.CfnOutput(this, key, { value });
    cdk.Tags.of(this).add("Application", "Workmate");
  }
}
const app = new cdk.App();
new WorkmateStack(app, "Workmate", {
  env: { account: process.env.CDK_DEFAULT_ACCOUNT, region: "eu-north-1" },
  description:
    "Workmate private productivity workspace — Stockholm serverless backend",
});
