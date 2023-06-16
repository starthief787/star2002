package main

import (
	dg "block_producers_uptime/delegation_backend"
	itn "block_producers_uptime/itn_uptime_analyzer"
	"context"
	"fmt"

	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go/aws"
	logging "github.com/ipfs/go-log/v2"
)

func main() {

	// Setting up logging for application

	logging.SetupLogging(logging.Config{
		Format: logging.JSONOutput,
		Stderr: true,
		Stdout: false,
		Level:  logging.LevelDebug,
		File:   "",
	})
	log := logging.Logger("itn availability script")
	log.Infof("itn availability script has the following logging subsystems active: %v", logging.GetSubsystems())

	// Empty context object and initializing memory for application

	ctx := context.Background()

	appCfg := itn.LoadEnv(log)

	awsCfg, err := config.LoadDefaultConfig(ctx, config.WithRegion(appCfg.Aws.Region))
	if err != nil {
		log.Fatalf("Error loading AWS configuration: %v", err)
	}

	app := new(dg.App)
	app.Log = log
	client := s3.NewFromConfig(awsCfg)

	awsctx := dg.AwsContext{Client: client, BucketName: aws.String(itn.GetBucketName(appCfg)), Prefix: appCfg.NetworkName, Context: ctx, Log: log}

	// Create Google Cloud client

	// sheetsService, err := sheets.NewService(ctx)
	// if err != nil {
	// 	log.Fatalf("Error creating Sheets service: %v", err)
	// 	return
	// }

	identities := itn.CreateIdentities(awsctx, log)

	fmt.Println(identities)

	// Go over identities and calculate uptime

	// for _, identity := range identities {

	// 	identity.GetUptime(ctx, client, log)

	// 	exactMatch, rowIndex, firstEmptyRow := identity.GetCell(sheetsService, log)

	// 	if exactMatch {
	// 		identity.AppendUptime(sheetsService, log, rowIndex)
	// 	} else if (!exactMatch) && (rowIndex == 0) {
	// 		identity.AppendNext(sheetsService, log)
	// 		identity.AppendUptime(sheetsService, log, firstEmptyRow)
	// 	} else if (!exactMatch) && (rowIndex != 0) {
	// 		identity.InsertBelow(sheetsService, log, rowIndex)
	// 		identity.AppendUptime(sheetsService, log, rowIndex+1)
	// 	}
	// }

	// itn.MarkExecution(sheetsService, log)

}
