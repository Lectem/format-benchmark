const fs = require('fs');
const path = require('path');
const util = require('util');

// json reading method
function readJson(path) {
    try {
        return JSON.parse(fs.readFileSync(path));
    } catch (error) {
        console.log("[ERROR] An error occured while reading:" + path);
        console.log(error);
        process.exit(1);
    }
}

// Makes sure that we are using the same context, and if not outputs a warning
// Returns the context without fields that are not related to a benchmark config
function checkConfigRelatedContextData(previousConfigContext, jsonFile, filePath) {
    // Copy context and remove fields that can change from one run to another
    newContext = { ...jsonFile.context };
    delete newContext.date;
    delete newContext.executable;
    delete newContext.load_avg;

    if (previousConfigContext) {
        if (!util.isDeepStrictEqual(previousConfigContext, newContext)) {
            console.warn(`[WARN] - Context in file '${filePath}' is different from the previous one, we suggest giving different Config to different contexts. (run the 'calcite upload -BC Config' command once per config)`);
        }
    }
    return newContext;
}

function mergeReportsPerExecutable(filesList)
{
    let partialConfigContext = null;
    testsuites = new Map();
    filesList.forEach(filePath => {
        const jsonFile = readJson(filePath);

        partialConfigContext = checkConfigRelatedContextData(partialConfigContext, jsonFile, filePath);

        const testsuiteName = path.basename(jsonFile.context.executable);
        if (!testsuites.get(testsuiteName)) {
            testsuites.set(testsuiteName, new Map());
        }
        const mergedResults = testsuites.get(testsuiteName);

        const benchsNoAggregate = jsonFile.benchmarks.filter(bench => bench.run_type === 'iteration');

        const res = benchsNoAggregate.reduce((results, benchmark) => {
            const perfTestResults = results.get(benchmark.run_name);
            // Note: we do not use benchmark.repetition_index as we want to be able to merge multiple reports
            if (perfTestResults) {
                perfTestResults.real_time.push(benchmark.real_time);
                perfTestResults.cpu_time.push(benchmark.cpu_time);
            }
            else {
                results.set(benchmark.run_name, {
                    name: benchmark.run_name,
                    unit: benchmark.time_unit,
                    real_time: [benchmark.real_time],
                    cpu_time: [benchmark.cpu_time],
                });
            }
            return results;
        }, mergedResults);
    });

    return testsuites;
}


function mergeReportsPerTestFunctionName(filesList)
{
    let partialConfigContext = null;
    testsuites = new Map();
    filesList.forEach(filePath => {
        const jsonFile = readJson(filePath);

        partialConfigContext = checkConfigRelatedContextData(partialConfigContext, jsonFile, filePath);

        
        const benchsNoAggregate = jsonFile.benchmarks.filter(bench => bench.run_type === 'iteration');

        testsuites = benchsNoAggregate.reduce((testsuites, benchmark) => {

            const splitBenchName = benchmark.run_name.split('/');

            const testsuiteName = path.basename(splitBenchName[0]);
            const testName = splitBenchName.length > 1 ? splitBenchName.slice(1).join('/') : benchmark.run_name;

            if (!testsuites.get(testsuiteName)) {
                testsuites.set(testsuiteName, new Map());
            }
            const tests = testsuites.get(testsuiteName);    
            const perfTestResults = tests.get(testName);
            // Note: we do not use benchmark.repetition_index as we want to be able to merge multiple reports
            if (perfTestResults) {
                perfTestResults.real_time.push(benchmark.real_time);
                perfTestResults.cpu_time.push(benchmark.cpu_time);
            }
            else {
                tests.set(testName, {
                    name: testName,
                    unit: benchmark.time_unit,
                    real_time: [benchmark.real_time],
                    cpu_time: [benchmark.cpu_time],
                });
            }
            return testsuites;
        }, testsuites);
    });

    return testsuites;
}



function getTestSuites(filesList) {
    const testsuites = mergeReportsPerExecutable(filesList);
    //const testsuites = mergeReportsPerTestFunctionName(filesList);

    const testsuitesAsArray = [];

    testsuites.forEach((content, name) => {
        testsuitesAsArray.push({
            name,
            tests: [...content.values()].map(testRes => {
                return {
                    name: testRes.name,
                    dataPoints: [
                        {
                            name: 'real_time',
                            values: testRes.real_time,
                            unit: testRes.unit,
                            aggregationPolicy: 'median',
                            diffPolicy: 'relativeDifference',
                            regressionPolicy: 'lessIsBetter',
                            regressionArgument: 20

                        },
                        {
                            name: 'cpu_time',
                            values: testRes.cpu_time,
                            unit: testRes.unit,
                            aggregationPolicy: 'median',
                            diffPolicy: 'relativeDifference',
                            regressionPolicy: 'lessIsBetter',
                            regressionArgument: 20
                        }
                    ]
                }
            })
        });
    });

    return testsuitesAsArray;

}


module.exports = async function () {
    if (!process.env.BENCHMARK_BENCHMARK_OUT) {
        console.error('[Error] - The BENCHMARK_BENCHMARK_OUT env variable was not set');
        process.exit(1);
    }

    const filesList = process.env.BENCHMARK_BENCHMARK_OUT.split(path.delimiter);
    const testSuites = getTestSuites(filesList);

    // return all test suites
    return {
        testSuites
    }
};
