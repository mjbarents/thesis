require(lattice)
require(rtdists)
require(pso)

##### get the data (as you did before)
dat1 <- read.csv("k_mat_leendert_S1.csv", sep=";")
dat2 <- read.csv("k_mat_leendert_S2.csv", sep=";")

# for now, assume this is the same session
dat <- rbind(dat1, dat2)

# exclude trials that are excessively long
dat <- dat[dat$RT<5000,]

# exclude trials that are excessively short
dat <- dat[dat$RT>200,]

# exclude individual level outliers over 3z
dat <- dat[unlist(with(dat, tapply(RT, PP_nr, scale))) < 3,]
dat <- dat[unlist(with(dat, tapply(RT, PP_nr, scale))) > -3,]

### recode -----
# we recode the trials as three conditions:
# Conflict: real trials
# Global: filler trials where the match with the original stimulus is on the global level
# Local: filler trials where the match with the original stimulus is on the local level
dat$condition <- factor(dat$filler_matches); levels(dat$condition) <- c("Conflict", "Global","Local")
dat$accuracy <- dat$filler_correct=="true"
dat$choice <- dat$pp_pref
dat$choice[dat$choice==""] <- with(dat[dat$choice=="",], ifelse(accuracy, 
                                                                ifelse(condition=="Global","global", "local"),
                                                                ifelse(condition=="Global","local", "global")))
dat$choice <- factor(dat$choice)
dat$Pg <- dat$choice=="global"
dat$rt <- dat$RT/1000 # in s
dat$subject <- as.factor(dat$PP_nr)
levels(dat$subject) <- 1:nlevels(dat$subject)

# only include relevant columns
dat <- dat[,c("subject","condition","rt", "accuracy", "choice", "Pg")]
dat <- droplevels(dat[dat$condition!="Conflict",]) # only focus on filler trials

#accumulation towoard true/false, because: baias to responses, we don't want to assume which response is true or false
dat$bound <- c('lower','upper')[dat$accuracy+1] # dat$response here is "correct" or "incorrect"

obj2 <- function(pars, rt, response, pred=F) { #LvM: added a pred parameter, to return the predicted likelihoods for all trials
	v <- pars[1]
	
	eta <- pars[2] #variability of drift rate
	a <- pars[3] #threshold
	sz <- pars[4]*a # because ddiffusion expects "Absolute" start point. start point var is actually U[z-sz/2, z+sz/2], so sz < 2*z and sz< a-2*z (because z-2*z/2 =0 and z+a-z*2/2=a)
	# in our case, because z=.5, sz < 1 and sz < a-1 (and sz>=0)
	Ter <- pars[5] #non-dec. time
	st0 <- pars[6] #variablity of Ter
	z <- pars[7]*a # because ddiffusion expects "Absolute" start point

	densities <- tryCatch( # the tryCatch constructoin makes sure that an erro does not crash your code
		ddiffusion(rt, response=response,
				   a=a, v=v, t0=Ter, 
				   sz=sz, z=z, 
				   st0=st0, sv=eta,s=.1), 
		error = function(e) 0)
	  if (pred) return(densities) else {
	  	if (any(densities == 0)) return(1e6)
	  	return(-sum(log(densities)))  
	      # densities are the likelihoods of each data point. You want to multiply these chances, which is equivalent to the sum of the logs
	      # note the minus sign: To maximize likelihood, we typically minimize the negative summed log likelihood	
	  }
}

obj <- function(pars, rt, response, cond) { # the new objective function that provides constraint (ie that you assume two pars are the same)
	
	pars <- constrainpars(pars)
	
	res <-  obj2(pars[1:7], rt[cond=="Global"], response[cond=="Global"]) # ie, parameters 1-7 are for global, rest for Local
	res <- res + obj2(pars[c(8:14)], rt[cond=="Local"], response[cond=="Local"])
	return(res)
}

# constraining parameters
constrainpars <- function(pars) {
  
  npar <- length(pars)
  
  ### what parameters are fixed to a default? 
  pars[seq(2, npar, npar/2)] <- 0 # no eta = variability of drift rate
  pars[seq(4, npar, npar/2)] <- 0 # no sz = variability of bias?
  pars[seq(6, npar, npar/2)] <- 0 # no st0 = variablity of Ter
  
  #pars[seq(7, npar, npar/2)] <- 0.5 # no z = precognition, ie no bias towards correct responses

  ### what parameters are constrained acorss conditions?
  ### uncomment these when relevant
  #pars[seq(1, npar, npar/2)] <- pars[1] # v = Mean drift rate
  #pars[seq(3, npar, npar/2)] <- pars[3] # a = Boundary seperation
  pars[seq(5, npar, npar/2)] <- pars[5] # Ter = Non decision time
  pars
}


########### estimate parameters for each participant ##############3

# if you have an initial set of parameters, you can use those as starting points (otherwise NULL). This is useful for model simplification:
# start with the most complex model (free parameters for every quantifier and speed stress condition), then iteratively simplify, using the
# optimal parameters so far as initial start points for the search
# If we already have an initial fit:
try(load("pars/parameterSet_eta_sz_st0_Ter.Rdata")); 
if (exists("fit")) {
    inits <- fit
} else {
    inits <- NULL
}

# estimate parameters for each stage and condition
fit <- data.frame(subject=levels(dat$subject), 
				  cond=rep(levels(dat$condition), each=nlevels(dat$subject)),
				  v=NA, eta=NA, a=NA, sz=NA, Ter=NA, st0=NA, z=NA, SLL=NA, k=NA)
parnames <- c('v','eta','a','sz','Ter','st0','z') # names of parameters


for (subject in levels(dat$subject)) { # subject: participant ID (factor)
    cat(subject, "\n")
    # in the psoptim function below, you need to include upper bounds and lower bounds of the parameter search space. Here I defined them 
    # adhoc, but you could also specify these based on the meta analysis from Tran et al 2019
	ub <- rep(c(4,3,3,2,min(dat$rt[dat$subject==subject])*.975,min(dat$rt[dat$subject==subject])*.95,.95),2)##sz z debug
	lb <- rep(c(-4,1e-10,1e-10,1e-10,1e-10,1e-10,1e-10),2) # usually zero
	if (is.null(inits)) { # if you don't have an initial estimate, define start points for the search
		init <- runif(length(ub), lb,ub)
    init <- constrainpars(init)
    abstol <- -1e4
	} else { # use the initial estimates as start points
		abstol <- inits$obj[inits$subject==subject][1] - abs(inits$obj[inits$subject==subject][1]/2)
		init <- constrainpars(unlist(c(t(inits[inits$subject==subject,parnames]))))
	}
	cat("Tol: ", abstol, "\n")
	# ps optim (particle swarm optimization, see Clerc 2010) optimizes a set of parameters using multiple parallel searches of the parameter space, with some smart optimization steps (mutatoin, migration etc)
	res <- psoptim(init, obj, lower=lb, upper=ub, rt=dat$rt[dat$subject==subject], 
		  response=dat$bound[dat$subject==subject], cond=dat$condition[dat$subject==subject],
		  control=list(trace=0, maxit=1000, abstol=abstol))

	# make sure that the constraints you had on the parameters while optimizing are also enforced in the output
	pars <- constrainpars(res$par)

	# store the result in your data frame
	fit[fit$subject==subject,parnames] <- matrix(pars, 2, length(parnames), byrow=T)
	fit[fit$subject==subject,"SLL"] <- -res$value # summed log likelihood
	fit[fit$subject==subject,"k"] <- sum(!unique(pars)%in%c(0,.5,1)) #number of free paramters. You need to make sure this is set correctly, since it is used in the model comparison later on! (perhaps a smart function for this?)
	save(fit, file="pars/parameterSet_eta_sz_st0_Ter.Rdata")
	cat("Done!", res$value, "\n")
}



################## plot some results ###################
generateData <- function(pars, N=1000) {
    # This function generates N trials, based on the parameters. It returns a data frame with rt, response
    # extract the parameters	
    v <- pars[1]
    eta <- pars[2] #variability of DR
    a <- pars[3] #threshold
    sz <- pars[4]*a # because ddiffusion expects "Absolute" start point. start point var is actually U[z-sz/2, z+sz/2], so sz < 2*z and sz< a-2*z (because z-2*z/2 =0 and z+a-z*2/2=a)
    # in our case, because z=.5, sz < 1 and sz < a-1 (and sz>=0)
    Ter <- pars[5] #non-dec. time
    st0 <- pars[6] #variablity of Ter
    z <- pars[7]*a # because ddiffusion expects "Absolute" start point
    
    res <- rdiffusion(n=N, a=a, v=v, t0=Ter, 
                      sz=sz, z=z, 
                      st0=st0, sv=eta,s=.1)
    return(res)
}


palette(c("cornflowerblue","green3","gold","red","grey","black"))
load("pars/parameterSet_eta_sz_st0_Ter.Rdata") # get the parameters 

# N: number of simulated trials per condition
N <- 5000

qps <- seq(0.1,.9,.2) # the RT quantile probabilities that you want to plot

pdf(file = 'results/parameterSet_eta_sz_st0_Ter.pdf')
par(mfcol=c(2,2), las=1, mar=c(4,5,1,1))
for (subject in fit$subject) {
    cat(subject, "\n")
	for (cond in levels(dat$condition)) {
        # the data that you fit
		rts <- dat$rt[dat$subject==subject&dat$condition==cond]
		response <- dat$accuracy[dat$subject==subject&dat$condition==cond]
		
		# predictions based on optimal parameters
		pars <- unlist(fit[fit$subject==subject&fit$cond==cond, parnames])
		preds <- generateData(pars, N)
		
		# compute and plot the prediction/model
		max_p <- mean(preds$response=='upper') # probability of "upper" response (ie, that a quantifier correctly describes the sentence)
		q1 <- quantile(preds$rt[preds$response=="upper"], prob=qps, na.rm=T) #RT quantiles
		q2 <- quantile(preds$rt[preds$response=="lower"], prob=qps, na.rm=T)
		if (!all(is.na(c(q1,q2)))) { # ot sure why we have this: prob to catch a complete misfit or sthng
			matplot(cbind(q1,q2), cbind(qps*max_p, qps*(1-max_p)), type='b',col=1:2,
				ylab="Proportion", xlab="RT (s)", pch="X", xlim=range(rts),
				ylim=range(max_p, 0,.55, na.rm=T), main=cond, lwd=2)
		} else {
			matplot(rep(0:4,2), cbind(qps*max_p, qps*(1-max_p)), type='n',col=1:2,
				ylab="Proportion", xlab="RT (s)", pch="X", 
				ylim=range(max_p, 0,.55, na.rm=T), main=cond, lwd=2)
		}
        
		# add prob. and quantiles from the data		
		max_p <- mean(response)
		q1 <- quantile(dat$rt[dat$subject==subject&dat$condition==cond&dat$accuracy], prob=qps)
		q2 <- quantile(dat$rt[dat$subject==subject&dat$condition==cond&!dat$accuracy], prob=qps)
		points(c(q1,q2), c(qps*max_p, qps*(1-max_p)), pch="O",
			col=rep(1:2, each=length(qps)), lwd=2)

		legend("bottomright",legend=c("Data","Model","TRUE","FALSE"), pch=c("O","X",NA, NA), 
			col=c(6,6, 1,2), bty='n', lty=c(NA, NA, 1:2), lwd=2)
			legend("topleft",legend=subject, bty='n')
	}
}
dev.off()

### parameters?
pdf(file = 'results/sum_parameterSet_eta_sz_st0_Ter.pdf')
plotparbox <- function(pname, fit, ylab=pname) {
	boxplot(fit[[pname]]~fit$cond, ylab=ylab, col=1:2)
	tmp <- t.test(fit[[pname]][fit$cond=="Global"]-fit[[pname]][fit$cond=="Local"])
	legend("bottomleft", legend=c(paste("t=",round(tmp$statistic,2)), paste("p=",round(tmp$p.value,3))), bty='n')
}

par(mfcol=c(2,3), las=1, mar=c(4,5,1,1))
for (pname in parnames) {
	plotparbox(pname, fit)
}
dev.off()

########## model comparison ##############
fnames <- list.files(pattern="parameter")

fits <- NULL
for (f in fnames){
	load(f)
	fit$nPar <- fit$k[fit$subject==1]
	fit$n <- c(with(dat, tapply(rt, list(subject, condition), length)))
	fit$aic <- with(fit, 2*nPar - 2*SLL) # see eg wikipedia AIC
	fit$bic <- with(fit, log(n)*nPar - 2*SLL) #BIC
	fit$mdl <- gsub('parameterSet_','',gsub('.Rdata','',f))
	fits <- rbind(fits, fit)
}

fits <- fits[fits$cond=="Global",] # because we fit all conditions at once
fits$mdl <- factor(fits$mdl)

schwarz.weights <- function (bic, na.rm = T)
{
  d.bic <- bic - min(bic, na.rm = na.rm)
  exp(-0.5 * d.bic)/sum(exp(-0.5 * d.bic), na.rm = na.rm)
}

# heatmap based on AIC. Colors indicate the best fitting models
my_palette <- colorRampPalette(c("red", "yellow", "green"))(n = 99)
wide <- reshape(fits[,c("subject","aic","mdl")], idvar = "subject",
                timevar = "mdl", direction = "wide")
mat_data <- apply(wide[,-1],1,schwarz.weights)
rownames(mat_data) <- levels(fits$mdl)
colnames(mat_data) <- levels(fit$subject)

weights <- t(mat_data)
colindex <- order(colSums(weights))

# sort individuals according to a hierarchical cluster
rowcluster <- as.dendrogram(hclust(dist(weights)))
rowindex <- order.dendrogram(rowcluster)


levelplot(weights[rowindex, colindex[]],col.regions=my_palette, 
	xlab="Participant", ylab="Model",aspect=0.5,margin=F,
	colorkey=list(col=my_palette, interpolate=T, raster=T, at=seq(0,1,.2)))

