###############################################################################
# (c) Copyright 2016, Arimo, Inc. All Rights Reserved.
# @author: minhtran
#
# This file contains implementations with respect to the feature engineering 
# of stock market data.

library(TTR)

# Set up some configurations
numOfFutureDays <- 10 
numOfPastDays <- 10 
expectedBenefit <- 0.025 
decisionThreshold <- 0.1

# This function is to automatically create a new dataframe with past/future 
# values for modeling.
addPastFutureValues <- function(formula, df, k=10, m=10) {
    
    # Number of observations
    dataLength <- nrow(df)
    
    # Feature to add
    featureName <- attr(terms(formula), "term.labels")
    data <- df[, featureName]
    
    # Generate the data frame
    # First, add the past
    df <- df[c((m+1):dataLength), ]
    colNames <- colnames(df)
    if (m>0) {
        for (i in (1:m)) {
            df <- data.frame(df, data[((m-i+1):(dataLength-i))])
            colNames <- c(colNames, paste0(featureName, 'Past', i))
        }
    }
    
    # Second, add the future
    df <- df[c(1:(dataLength-m-k)), ]
    if (k>0) {
        for (i in (1:k)) {
            df <- data.frame(df, data[((m+i+1):(dataLength-k+i))])
            colNames <- c(colNames, paste0(featureName, 'Future', i))    
        }
    }
    colnames(df) <- colNames
    return (df)
}

# Main function
run <- function(dataFile) {
    # Read file and guarantee time order
    df <- read.csv(paste0(inputPath, dataFile), sep=',')
    df$Date <- as.Date(df$Date)
    df <- df[order(df$Date), ]
        
    # Compute and add the T.index, the regression target for predictive 
    # modeling
    df$AverPrice <- (df$High + df$Close + df$Low) / 3
    averPriceDF <- addPastFutureValues(formula('~ AverPrice'), df, 
                                       k=numOfFutureDays, m=0)
    averPriceListCols <- NULL
    for (col in (1:numOfFutureDays)) {
        averPriceListCols <- c(averPriceListCols, 
                               paste0('AverPriceFuture', col))    
    }
    for (col in averPriceListCols) {
        averPriceDF[col] <- (averPriceDF[col] - averPriceDF['Close']) / 
                                                averPriceDF['Close']
    }
    averPriceDF$T.ind <- apply(averPriceDF[averPriceListCols], 1,
                function(x) sum(x[x>expectedBenefit | x<-expectedBenefit]))
        
    # Add 10 past days of Close
    pastCloseDF <- addPastFutureValues(formula('~ Close'), averPriceDF,
                                       k=0, m=numOfPastDays)
    closeListCols <- NULL
    for (col in (1:numOfPastDays)) {
        closeListCols <- c(closeListCols, paste0('ClosePast', col))   
    }
    for (col in closeListCols) {
        pastCloseDF[col] <- (pastCloseDF['Close'] - pastCloseDF[col]) / 
                                                    pastCloseDF[col]
    }
    
    # Add more predictors
    pastCloseDF$ATR <- ATR(pastCloseDF[c('High', 'Low', 'Close')])[,'atr']
    pastCloseDF$SMI <- SMI(pastCloseDF[c('High', 'Low', 'Close')])[,'SMI']
    pastCloseDF$ADX <- ADX(pastCloseDF[c('High', 'Low', 'Close')])[,'ADX']
    pastCloseDF$Aroon <- aroon(pastCloseDF[c('High','Low')])[,'oscillator']
    pastCloseDF$BB <- BBands(pastCloseDF[c('High','Low','Close')])[,'pctB']
    pastCloseDF$Chaikin <- chaikinVolatility(pastCloseDF[c('High', 'Low')])
    pastCloseDF$CLV <- EMA(CLV(pastCloseDF[c('High', 'Low', 'Close')]))
    pastCloseDF$EMV <- EMV(pastCloseDF[c('High', 'Low')], 
                                        pastCloseDF['Volume'])[, 2]
    pastCloseDF$MACD <- MACD(pastCloseDF['Close'])[, 2]
    pastCloseDF$MFI <- MFI(pastCloseDF[c('High', 'Low', 'Close')], 
                                        pastCloseDF['Volume'])
    pastCloseDF$SAR <- SAR(pastCloseDF[c('High', 'Close')])
    pastCloseDF$Volat <- volatility(pastCloseDF[c('Open', 'High', 'Low', 
                                                  'Close')], calc='garman')
    
    # Create classification target indicator (1: Buy, -1: Sell, 0: Hold)
    pastCloseDF$Decision[pastCloseDF$T.ind > decisionThreshold] <- 1 
    pastCloseDF$Decision[pastCloseDF$T.ind < -decisionThreshold] <- -1 
    pastCloseDF$Decision[pastCloseDF$T.ind <= decisionThreshold & 
                         pastCloseDF$T.ind>=-decisionThreshold] <- 0
    pastCloseDF$Decision <- as.factor(pastCloseDF$Decision)
        
    finalDF <- pastCloseDF[complete.cases(pastCloseDF), c('Date', 'Open', 
            'High', 'Low', 'Close', 'Volume', 'Adjusted.Close', closeListCols,
            'ATR', 'SMI', 'ADX', 'BB', 'Aroon', 'Chaikin','MFI', 'SAR', 'Volat',
            'EMV', 'CLV', 'MACD', 'T.ind', 'Decision')]
        
    # Save transformed file
    write.table(data.frame(dataFile, nrow(df), nrow(finalDF), df$Date[1], 
            finalDF$Date[1], df$Date[nrow(df)], finalDF$Date[nrow(finalDF)]), 
            file=paste0(outputPath, 'log.txt'), append=TRUE, sep=' ',
            col.names=F, row.names=F)        
    write.csv(finalDF, file=paste0(outputPath, dataFile), row.names=F)
}

inputPath <- 'yahoo_data/data/'
outputPath <- 'yahoo_data/transform/'
dataFiles <- list.files(path='yahoo_data/data')

for (dataFile in dataFiles) {
    tryCatch({run(dataFile)}, 
             warning = function(w) {print(paste0('Waring in ', dataFile))}, 
             error = function(e) {print(paste0('Error in ', dataFile))})
}
