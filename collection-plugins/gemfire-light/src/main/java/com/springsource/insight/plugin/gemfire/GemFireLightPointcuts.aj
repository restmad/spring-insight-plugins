/**
 * Copyright (c) 2009-2011 VMware, Inc. All Rights Reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *         http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package com.springsource.insight.plugin.gemfire;

import com.gemstone.gemfire.cache.query.Query;
import com.gemstone.gemfire.cache.client.internal.AbstractOp;
import com.gemstone.gemfire.cache.client.internal.Connection;

public aspect GemFireLightPointcuts {
    /**
     * Query point cut
     */
    public pointcut queryCollectionPoint(): execution(* Query.execute*(..));

    /**
     * Remote point cut
     */
    public pointcut remoteCollectionPoint(): execution(void AbstractOp.sendMessage(Connection));

}
