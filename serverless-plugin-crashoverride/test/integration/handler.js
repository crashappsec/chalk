module.exports.hello = async (_event) => {
    return {
        statusCode: 200,
        body: JSON.stringify({ message: 'Hello World' }),
    };
};
